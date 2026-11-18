#import "CrIOSExtensionManagingV1.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const NSInteger kSettingsExtensionsItemType = 9001;
static const NSInteger kSettingsExtensionsSectionID = 9001;

static IMP gOrigSettingsLoadModel = NULL;
static IMP gOrigSettingsDidSelectRow = NULL;

@protocol CrTableViewModel <NSObject>
- (BOOL)hasSectionForSectionIdentifier:(NSInteger)sectionIdentifier;
- (void)addSectionWithIdentifier:(NSInteger)sectionIdentifier;
- (void)insertSectionWithIdentifier:(NSInteger)sectionIdentifier
                            atIndex:(NSUInteger)index;
- (void)addItem:(id)item toSectionWithIdentifier:(NSInteger)sectionIdentifier;
- (id)itemAtIndexPath:(NSIndexPath *)indexPath;
@end

@protocol CrTableViewDetailIconItem <NSObject>
- (instancetype)initWithType:(NSInteger)type;
- (NSInteger)type;
- (void)setText:(NSString *)text;
- (void)setDetailText:(NSString *)detailText;
- (void)setIconImage:(UIImage *)iconImage;
- (void)setIconTintColor:(UIColor *)iconTintColor;
- (void)setIconBackgroundColor:(UIColor *)iconBackgroundColor;
- (void)setAccessoryType:(UITableViewCellAccessoryType)accessoryType;
- (void)setAccessibilityIdentifier:(NSString *)accessibilityIdentifier;
@end

@protocol CrSettingsTableViewController <NSObject>
- (id<CrTableViewModel>)tableViewModel;
@end

@protocol CrSettingsNavigationController <NSObject>
- (void)closeSettings;
@end

static id<CrIOSExtensionManagingV1> ManagerInstanceForClassName(NSString *className) {
  Class cls = NSClassFromString(className);
  if (!cls || ![cls respondsToSelector:@selector(sharedManager)]) {
    return nil;
  }
  id<CrIOSExtensionManagingV1> manager =
      ((id<CrIOSExtensionManagingV1> (*)(Class, SEL))objc_msgSend)(
          cls, @selector(sharedManager));
  if (!manager ||
      ![manager respondsToSelector:@selector(extensionsWithError:)] ||
      ![manager respondsToSelector:@selector(setExtensionWithID:enabled:error:)]) {
    return nil;
  }
  return manager;
}

static id<CrIOSExtensionManagingV1> ResolveExtensionManager(NSString **outError) {
  id<CrIOSExtensionManagingV1> prod =
      ManagerInstanceForClassName(@"CrIOSExtensionManagerV1");
  if (prod) {
    return prod;
  }
#if defined(ENABLE_DIAGNOSTIC_BRIDGE) && ENABLE_DIAGNOSTIC_BRIDGE
  id<CrIOSExtensionManagingV1> diag =
      ManagerInstanceForClassName(@"CrIOSDiagnosticPinnedExtensionManager");
  if (diag) {
    return diag;
  }
#endif
  if (outError) {
    *outError = @"Extension bridge unavailable";
  }
  return nil;
}

@interface ExtensionEntryModel : NSObject
@property(nonatomic, copy) NSString *extensionId;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL removable;
@property(nonatomic, copy) NSString *optionsPageURL;
@end

@implementation ExtensionEntryModel
@end

static NSArray<ExtensionEntryModel *> *LoadExtensionsSnapshot(NSString **outError) {
  if (![NSThread isMainThread]) {
    if (outError) *outError = @"Main thread required";
    return nil;
  }
  id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(outError);
  if (!manager) {
    return nil;
  }

  NSError *error = nil;
  NSArray<NSDictionary<NSString *, id> *> *rawItems =
      [manager extensionsWithError:&error];
  if (!rawItems) {
    if (outError) {
      *outError = error.localizedDescription.length > 0
                      ? error.localizedDescription
                      : @"Failed to query extensions";
    }
    return nil;
  }

  NSMutableArray<ExtensionEntryModel *> *entries =
      [NSMutableArray arrayWithCapacity:rawItems.count];
  for (id obj in rawItems) {
    if (![obj isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *dict = (NSDictionary *)obj;
    id rawId = dict[@"id"];
    if (![rawId isKindOfClass:NSString.class] || ((NSString *)rawId).length == 0) {
      continue;
    }
    id rawName = dict[@"name"];
    id rawVersion = dict[@"version"];
    id rawEnabled = dict[@"enabled"];
    id rawRemovable = dict[@"removable"];
    id rawOptionsURL = dict[@"optionsPageURL"];

    ExtensionEntryModel *entry = [[ExtensionEntryModel alloc] init];
    entry.extensionId = (NSString *)rawId;
    entry.name = ([rawName isKindOfClass:NSString.class] &&
                  ((NSString *)rawName).length > 0)
                     ? (NSString *)rawName
                     : entry.extensionId;
    entry.version = [rawVersion isKindOfClass:NSString.class]
                        ? (NSString *)rawVersion
                        : @"";
    entry.enabled = [rawEnabled isKindOfClass:NSNumber.class]
                        ? [(NSNumber *)rawEnabled boolValue]
                        : NO;
    entry.removable = [rawRemovable isKindOfClass:NSNumber.class] &&
        [rawRemovable boolValue] &&
        [manager respondsToSelector:@selector(uninstallExtensionWithID:completion:)];
    if (entry.enabled && [rawOptionsURL isKindOfClass:NSString.class] &&
        [(NSString *)rawOptionsURL hasPrefix:@"chrome-extension://"]) {
      entry.optionsPageURL = (NSString *)rawOptionsURL;
    }
    [entries addObject:entry];
  }

  [entries sortUsingComparator:^NSComparisonResult(ExtensionEntryModel *a,
                                                   ExtensionEntryModel *b) {
    NSComparisonResult cmp = [a.name localizedCaseInsensitiveCompare:b.name];
    return cmp != NSOrderedSame ? cmp : [a.extensionId compare:b.extensionId];
  }];
  return [entries copy];
}

static BOOL SetExtensionEnabled(NSString *extensionId,
                                BOOL targetEnabled,
                                BOOL *outActualEnabled,
                                NSString **outOptionsPageURL,
                                NSString **outError) {
  if (![NSThread isMainThread]) {
    if (outError) *outError = @"Main thread required";
    return NO;
  }
  if (!extensionId.length) {
    if (outError) *outError = @"Empty extension ID";
    return NO;
  }
  id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(outError);
  if (!manager) {
    return NO;
  }

  NSError *error = nil;
  BOOL ok = [manager setExtensionWithID:extensionId
                                enabled:targetEnabled
                                  error:&error];
  BOOL actual = outActualEnabled ? *outActualEnabled : !targetEnabled;
  NSString *refreshedOptionsURL = nil;
  BOOL foundInLatest = NO;
  NSError *readError = nil;
  NSArray<NSDictionary<NSString *, id> *> *latest =
      [manager extensionsWithError:&readError];
  for (id obj in latest) {
    if (![obj isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *dict = (NSDictionary *)obj;
    if ([dict[@"id"] isKindOfClass:NSString.class] &&
        [(NSString *)dict[@"id"] isEqualToString:extensionId] &&
        [dict[@"enabled"] isKindOfClass:NSNumber.class]) {
      foundInLatest = YES;
      actual = [(NSNumber *)dict[@"enabled"] boolValue];
      id rawOptionsURL = dict[@"optionsPageURL"];
      if (actual && [rawOptionsURL isKindOfClass:NSString.class] &&
          [(NSString *)rawOptionsURL hasPrefix:@"chrome-extension://"]) {
        refreshedOptionsURL = [(NSString *)rawOptionsURL copy];
      }
      break;
    }
  }
  if (outActualEnabled) *outActualEnabled = actual;
  if (outOptionsPageURL && (foundInLatest || !actual)) {
    *outOptionsPageURL = actual ? refreshedOptionsURL : nil;
  }
  BOOL confirmed = ok && foundInLatest && actual == targetEnabled;
  if (!confirmed && outError) {
    if (!ok) {
      *outError = error.localizedDescription ?: @"Failed to update extension state";
    } else if (!foundInLatest) {
      *outError = readError.localizedDescription ?: @"Could not confirm the extension's state";
    } else {
      *outError = @"Chromium did not apply the requested state";
    }
  }
  NSLog(@"EXTENSIONS_MANAGER toggle id=%@ target=%d actual=%d ok=%d",
        extensionId, targetEnabled, actual, confirmed);
  return confirmed;
}

static id FindSceneHandlerForViewController(UIViewController *vc) {
  SEL sceneHandlerSel = NSSelectorFromString(@"sceneHandler");
  UINavigationController *nav = vc.navigationController;
  for (UIViewController *candidate in nav.viewControllers) {
    if ([candidate respondsToSelector:sceneHandlerSel]) {
      id handler = ((id (*)(id, SEL))objc_msgSend)(candidate, sceneHandlerSel);
      if (handler) return handler;
    }
  }
  if (nav && [nav respondsToSelector:sceneHandlerSel]) {
    id handler = ((id (*)(id, SEL))objc_msgSend)(nav, sceneHandlerSel);
    if (handler) return handler;
  }
  UIViewController *presenting =
      nav ? nav.presentingViewController : vc.presentingViewController;
  if (presenting && [presenting respondsToSelector:sceneHandlerSel]) {
    id handler = ((id (*)(id, SEL))objc_msgSend)(presenting, sceneHandlerSel);
    if (handler) return handler;
  }
  return nil;
}

static void PresentOptionsAlert(UIViewController *presenter,
                                NSString *title,
                                NSString *message) {
  if (!presenter) return;
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

static BOOL OpenOptionsPageInBrowser(UIViewController *fromVC,
                                     ExtensionEntryModel *entry,
                                     NSString **outError) {
  if (!entry || !entry.enabled) {
    if (outError) {
      *outError = [NSString
          stringWithFormat:@"Enable %@ before opening its options page.",
                           entry.name.length ? entry.name : (entry.extensionId ?: @"extension")];
    }
    return NO;
  }

  NSString *urlStr = [entry.optionsPageURL copy];
  if (urlStr.length == 0 || ![urlStr hasPrefix:@"chrome-extension://"]) {
    if (outError) *outError = @"Extension declares no options page.";
    return NO;
  }

  NSURL *nsurl = [NSURL URLWithString:urlStr];
  Class crURLCls = NSClassFromString(@"CrURL");
  Class openNewTabCls = NSClassFromString(@"OpenNewTabCommand");
  SEL initWithNSURLSel = NSSelectorFromString(@"initWithNSURL:");
  SEL gurlSel = NSSelectorFromString(@"gurl");
  SEL cmdWithURLSel = NSSelectorFromString(@"commandWithURLFromChrome:");
  SEL closeAndOpenSel = NSSelectorFromString(@"closePresentedViewsAndOpenURL:");
  SEL openNewTabSel = NSSelectorFromString(@"openURLInNewTab:");

  id sceneHandler = FindSceneHandlerForViewController(fromVC);
  if (!nsurl || !crURLCls || !openNewTabCls || !sceneHandler ||
      ![crURLCls instancesRespondToSelector:initWithNSURLSel] ||
      ![crURLCls instancesRespondToSelector:gurlSel] ||
      ![openNewTabCls respondsToSelector:cmdWithURLSel]) {
    if (outError) *outError = @"Browser navigation bridge unavailable.";
    return NO;
  }

  __attribute__((objc_precise_lifetime)) id crURL =
      ((id (*)(id, SEL, NSURL *))objc_msgSend)([crURLCls alloc],
                                                initWithNSURLSel, nsurl);
  const void *gurlRef =
      crURL ? ((const void *(*)(id, SEL))objc_msgSend)(crURL, gurlSel) : NULL;
  if (!crURL || !gurlRef) {
    if (outError) *outError = @"Failed to construct CrURL.";
    return NO;
  }

  id cmd = ((id (*)(Class, SEL, const void *))objc_msgSend)(
      openNewTabCls, cmdWithURLSel, gurlRef);
  if (!cmd) {
    if (outError) *outError = @"Failed to construct OpenNewTabCommand.";
    return NO;
  }

  if ([sceneHandler respondsToSelector:closeAndOpenSel]) {
    ((void (*)(id, SEL, id))objc_msgSend)(sceneHandler, closeAndOpenSel, cmd);
  } else if ([sceneHandler respondsToSelector:openNewTabSel]) {
    ((void (*)(id, SEL, id))objc_msgSend)(sceneHandler, openNewTabSel, cmd);
  } else {
    if (outError) *outError = @"SceneCommands selector unavailable.";
    return NO;
  }

  NSLog(@"EXTENSIONS_MANAGER options id=%@ url=%@ ok=1",
        entry.extensionId, urlStr);
  return YES;
}

@interface ExtensionsManagerViewController
    : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSArray<ExtensionEntryModel *> *entries;
@property(nonatomic, copy) NSString *statusError;
@property(nonatomic, assign) BOOL importInProgress;
@end

static NSString *StoreIDFromListingURL(NSString *input) {
  NSURLComponents *url = [NSURLComponents componentsWithString:
      [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
  if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
      ![url.host.lowercaseString isEqualToString:@"chromewebstore.google.com"] ||
      url.user || url.password || (url.port && url.port.integerValue != 443)) {
    return nil;
  }
  NSArray<NSString *> *parts = url.path.pathComponents;
  if ((parts.count != 3 && parts.count != 4) ||
      ![parts[1] isEqualToString:@"detail"]) {
    return nil;
  }
  NSString *extensionID = parts.lastObject;
  NSCharacterSet *invalid =
      [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"].invertedSet;
  return extensionID.length == 32 &&
      [extensionID rangeOfCharacterFromSet:invalid].location == NSNotFound
      ? extensionID : nil;
}

@implementation ExtensionsManagerViewController

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Extensions";
  self.tableView.accessibilityIdentifier = @"kExtensionsManagerTableViewId";

  UIBarButtonItem *doneButton = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(handleDoneTapped:)];
  doneButton.accessibilityIdentifier = @"kExtensionsManagerDoneButtonId";
  self.navigationItem.rightBarButtonItem = doneButton;

  id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(NULL);
  if ([manager respondsToSelector:@selector(prepareSignedExtensionAtPath:completion:)] &&
      [manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)] &&
      [manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
    UIBarButtonItem *importButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"plus"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(pickExtensionFile)];
    importButton.accessibilityLabel = @"Import from Files";
    importButton.accessibilityIdentifier = @"kExtensionsImportFromFilesButtonId";
    if ([manager respondsToSelector:@selector(prepareStoreExtensionWithID:completion:)]) {
      __weak ExtensionsManagerViewController *weakSelf = self;
      importButton = [[UIBarButtonItem alloc]
          initWithImage:[UIImage systemImageNamed:@"plus"]
                   menu:[UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:@"From Chrome Web Store Link…"
                            image:[UIImage systemImageNamed:@"link"]
                       identifier:nil handler:^(__unused UIAction *action) {
          [weakSelf promptForStoreLink];
        }],
        [UIAction actionWithTitle:@"Import from Files…"
                            image:[UIImage systemImageNamed:@"folder"]
                       identifier:nil handler:^(__unused UIAction *action) {
          [weakSelf pickExtensionFile];
        }],
      ]]];
      importButton.accessibilityLabel = @"Add Extension";
      importButton.accessibilityIdentifier = @"kExtensionsAddButtonId";
    }
    self.navigationItem.rightBarButtonItems = @[doneButton, importButton];
  }

  [self reloadSnapshot];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadSnapshot];
}

- (void)handleDoneTapped:(id)sender {
  (void)sender;
  UINavigationController *nav = self.navigationController;
  Class settingsNavCls = NSClassFromString(@"SettingsNavigationController");
  if (nav && settingsNavCls && [nav isKindOfClass:settingsNavCls] &&
      [nav respondsToSelector:@selector(closeSettings)]) {
    [(id<CrSettingsNavigationController>)nav closeSettings];
    return;
  }
  if (nav && nav.presentingViewController) {
    [nav dismissViewControllerAnimated:YES completion:nil];
    return;
  }
  if (self.presentingViewController) {
    [self dismissViewControllerAnimated:YES completion:nil];
    return;
  }
  if (nav) {
    [nav popViewControllerAnimated:YES];
  }
}

- (void)reloadSnapshot {
  NSString *err = nil;
  NSArray<ExtensionEntryModel *> *items = LoadExtensionsSnapshot(&err);
  self.entries = items ?: @[];
  self.statusError = err;
  [self.tableView reloadData];
}

- (void)confirmRemovalOfExtension:(ExtensionEntryModel *)entry {
  if (self.importInProgress || self.presentedViewController) return;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"Remove %@?", entry.name]
      message:@"The extension will stop running in this profile."
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
  __weak ExtensionsManagerViewController *weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Remove"
      style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
    ExtensionsManagerViewController *view = weakSelf;
    id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(NULL);
    if (!view || view.importInProgress) return;
    if (![manager respondsToSelector:@selector(uninstallExtensionWithID:completion:)]) {
      [view reloadSnapshot];
      return;
    }
    view.importInProgress = YES;
    [manager uninstallExtensionWithID:entry.extensionId
                           completion:^(BOOL removed, NSError *error) {
      ExtensionsManagerViewController *liveView = weakSelf;
      liveView.importInProgress = NO;
      [liveView reloadSnapshot];
      if (!removed || error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (liveView.viewIfLoaded.window) {
            PresentOptionsAlert(liveView, removed ? @"Cleanup Incomplete" : @"Could Not Remove Extension",
                error.localizedDescription ?: @"Try again.");
          }
        });
      }
    }];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (UIButton *)buildManageButtonForEntry:(ExtensionEntryModel *)entry {
  UIButtonConfiguration *config = [UIButtonConfiguration borderedButtonConfiguration];
  config.title = @"Manage";
  UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
  button.accessibilityIdentifier =
      [NSString stringWithFormat:@"kExtensionManageButton_%@", entry.extensionId];
  button.accessibilityLabel = [NSString stringWithFormat:@"Manage %@", entry.name];
  __weak ExtensionsManagerViewController *weakSelf = self;
  NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
  if (entry.optionsPageURL.length > 0) {
    [actions addObject:[UIAction actionWithTitle:@"Options" image:[UIImage systemImageNamed:@"gear"]
        identifier:nil handler:^(__unused UIAction *action) {
      ExtensionsManagerViewController *view = weakSelf;
      if (!view) return;
      NSString *error = nil;
      if (!OpenOptionsPageInBrowser(view, entry, &error)) {
        PresentOptionsAlert(view, @"Options Unavailable", error);
      }
    }]];
  }
  if (entry.removable) {
    UIAction *remove = [UIAction actionWithTitle:@"Remove…"
        image:[UIImage systemImageNamed:@"trash"] identifier:nil
        handler:^(__unused UIAction *action) {
      [weakSelf confirmRemovalOfExtension:entry];
    }];
    remove.attributes = UIMenuElementAttributesDestructive;
    [actions addObject:remove];
  }
  button.menu = [UIMenu menuWithChildren:actions];
  button.showsMenuAsPrimaryAction = YES;
  return button;
}

- (void)pickExtensionFile {
  if (self.importInProgress || self.presentedViewController) return;
  UTType *type = [UTType typeWithFilenameExtension:@"crx"];
  UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[type ?: UTTypeData] asCopy:YES];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)promptForStoreLink {
  if (self.importInProgress || self.presentedViewController) return;
  UIAlertController *prompt = [UIAlertController
      alertControllerWithTitle:@"Chrome Web Store Link"
      message:@"Paste a link to the extension’s Store listing."
      preferredStyle:UIAlertControllerStyleAlert];
  [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = @"https://chromewebstore.google.com/detail/…";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak UIAlertController *weakPrompt = prompt;
  __weak ExtensionsManagerViewController *weakSelf = self;
  [prompt addAction:[UIAlertAction actionWithTitle:@"Review" style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction *action) {
    NSString *extensionID = StoreIDFromListingURL(weakPrompt.textFields.firstObject.text);
    void (^start)(void) = ^{ [weakSelf prepareStoreID:extensionID]; };
    id<UIViewControllerTransitionCoordinator> transition = weakPrompt.transitionCoordinator;
    if (!transition ||
        ![transition animateAlongsideTransition:nil completion:^(__unused id context) { start(); }]) {
      dispatch_async(dispatch_get_main_queue(), start);
    }
  }]];
  [self presentViewController:prompt animated:YES completion:nil];
}

- (void)prepareStoreID:(NSString *)extensionID {
  if (self.importInProgress || !self.viewIfLoaded.window) return;
  if (!extensionID) {
    PresentOptionsAlert(self, @"Invalid Store Link", @"Choose a Chrome Web Store extension listing.");
    return;
  }
  id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(NULL);
  if (![manager respondsToSelector:@selector(prepareStoreExtensionWithID:completion:)]) {
    return;
  }
  self.importInProgress = YES;
  __weak ExtensionsManagerViewController *weakSelf = self;
  [manager prepareStoreExtensionWithID:extensionID
      completion:^(NSDictionary *prepared, NSError *error) {
    ExtensionsManagerViewController *view = weakSelf;
    if (!view) {
      if (prepared[@"token"]) [manager cancelPreparedExtensionWithToken:prepared[@"token"] error:nil];
    } else if (error || !prepared) {
      view.importInProgress = NO;
      if (view.viewIfLoaded.window) {
        PresentOptionsAlert(view, @"Could Not Prepare Extension",
                            error.localizedDescription ?: @"The Store did not provide a verified package.");
      }
    } else {
      [view reviewPreparedImport:prepared manager:manager];
    }
  }];
}

- (void)reviewPreparedImport:(NSDictionary *)prepared
                     manager:(id<CrIOSExtensionManagingV1>)manager {
  NSString *token = prepared[@"token"];
  if (!self.viewIfLoaded.window || self.presentedViewController) {
    [manager cancelPreparedExtensionWithToken:token error:nil];
    self.importInProgress = NO;
    return;
  }
  NSString *permissions = [prepared[@"permissions"] componentsJoinedByString:@", "];
  NSString *hosts = [prepared[@"hostPermissions"] componentsJoinedByString:@", "];
  NSString *description = [NSString stringWithFormat:
      @"Version %@ · Chrome Web Store signature verified\n\n"
       "Requested permissions: %@\n\nSite access: %@\n\n"
       "This extension is available until Chromium restarts.",
      prepared[@"version"], permissions.length ? permissions : @"None",
      hosts.length ? hosts : @"None"];
  UIAlertController *review = [UIAlertController alertControllerWithTitle:prepared[@"name"]
      message:description preferredStyle:UIAlertControllerStyleAlert];
  __weak ExtensionsManagerViewController *weakSelf = self;
  [review addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
      handler:^(__unused UIAlertAction *action) {
    [manager cancelPreparedExtensionWithToken:token error:nil];
    weakSelf.importInProgress = NO;
  }]];
  [review addAction:[UIAlertAction actionWithTitle:@"Add Extension" style:UIAlertActionStyleDefault
      handler:^(__unused UIAlertAction *action) {
    [manager confirmPreparedExtensionWithToken:token
        completion:^(NSDictionary *entry, NSError *error) {
      ExtensionsManagerViewController *view = weakSelf;
      view.importInProgress = NO;
      [view reloadSnapshot];
      if ((!entry || error) && view.viewIfLoaded.window) {
        PresentOptionsAlert(view, @"Could Not Import Extension",
                            error.localizedDescription ?: @"Chromium could not confirm the install.");
      }
    }];
  }]];
  [self presentViewController:review animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (self.importInProgress) return;
  NSURL *url = urls.firstObject;
  if (!url.isFileURL || [url.pathExtension caseInsensitiveCompare:@"crx"] != NSOrderedSame) {
    dispatch_async(dispatch_get_main_queue(), ^{
      PresentOptionsAlert(self, @"Could Not Import Extension", @"Choose a signed CRX file.");
    });
    return;
  }
  id<CrIOSExtensionManagingV1> manager = ResolveExtensionManager(NULL);
  if (![manager respondsToSelector:@selector(prepareSignedExtensionAtPath:completion:)]) {
    return;
  }
  self.importInProgress = YES;
  BOOL access = [url startAccessingSecurityScopedResource];
  __weak ExtensionsManagerViewController *weakSelf = self;
  [manager prepareSignedExtensionAtPath:url.path
      completion:^(NSDictionary *prepared, NSError *error) {
    if (access) [url stopAccessingSecurityScopedResource];
    void (^show)(void) = ^{
      ExtensionsManagerViewController *view = weakSelf;
      if (!view) {
        if (prepared[@"token"]) [manager cancelPreparedExtensionWithToken:prepared[@"token"] error:nil];
        return;
      }
      if (!prepared || error) {
        view.importInProgress = NO;
        if (view.viewIfLoaded.window) {
          PresentOptionsAlert(view, @"Could Not Import Extension",
                              error.localizedDescription ?: @"The file could not be verified.");
        }
        return;
      }
      [view reviewPreparedImport:prepared manager:manager];
    };
    id<UIViewControllerTransitionCoordinator> transition = controller.transitionCoordinator;
    if (!transition ||
        ![transition animateAlongsideTransition:nil completion:^(__unused id context) { show(); }]) {
      dispatch_async(dispatch_get_main_queue(), show);
    }
  }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  (void)section;
  return self.entries.count > 0 ? (NSInteger)self.entries.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  (void)section;
  if (self.statusError.length > 0) {
    return [NSString stringWithFormat:@"Extensions unavailable (%@).", self.statusError];
  }
  return @"Reload open pages for extension changes to take effect.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.entries.count == 0) {
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                               reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = self.statusError.length > 0
                              ? @"Extensions Unavailable"
                              : @"No Extensions Installed";
    cell.textLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessibilityIdentifier = @"kExtensionsEmptyStateCellId";
    return cell;
  }

  static NSString *const kReuseID = @"ExtensionEntryCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kReuseID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:kReuseID];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  }

  ExtensionEntryModel *entry = self.entries[(NSUInteger)indexPath.row];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.accessibilityIdentifier =
      [NSString stringWithFormat:@"kExtensionCell_%@", entry.extensionId];
  cell.textLabel.text = entry.name;
  cell.detailTextLabel.text = entry.version.length > 0
      ? [NSString stringWithFormat:@"Version %@", entry.version]
      : nil;

  [self configureAccessoryForCell:cell atRow:indexPath.row withEntry:entry existingSwitch:nil];
  return cell;
}

- (void)configureAccessoryForCell:(UITableViewCell *)cell
                            atRow:(NSInteger)row
                        withEntry:(ExtensionEntryModel *)entry
                   existingSwitch:(UISwitch *)existingSwitch {
  if (!cell) return;
  UISwitch *toggle = existingSwitch ?: [[UISwitch alloc] init];
  toggle.on = entry.enabled;
  toggle.tag = row;
  toggle.accessibilityIdentifier =
      [NSString stringWithFormat:@"kExtensionToggle_%@", entry.extensionId];
  toggle.accessibilityLabel =
      [NSString stringWithFormat:@"Enable %@", entry.name];
  [toggle removeTarget:self
                action:@selector(handleExtensionSwitch:)
      forControlEvents:UIControlEventValueChanged];
  [toggle addTarget:self
                action:@selector(handleExtensionSwitch:)
      forControlEvents:UIControlEventValueChanged];

  NSMutableArray *accessibilityElements = [NSMutableArray arrayWithObject:cell.textLabel];
  if (cell.detailTextLabel.text.length) {
    [accessibilityElements addObject:cell.detailTextLabel];
  }
  if (entry.removable || entry.optionsPageURL.length > 0) {
    UIButton *manage = [self buildManageButtonForEntry:entry];
    UIStackView *stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ manage, toggle ]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10.0;
    CGSize fit = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    stack.frame = CGRectMake(0, 0, ceil(fit.width), ceil(MAX(fit.height, 32.0)));
    cell.accessoryView = stack;
    [accessibilityElements addObject:manage];
  } else {
    cell.accessoryView = toggle;
  }
  [accessibilityElements addObject:toggle];
  cell.isAccessibilityElement = NO;
  cell.accessibilityElements = accessibilityElements;
}

- (void)applyToggleForRow:(NSInteger)row
            targetEnabled:(BOOL)targetEnabled
                     cell:(UITableViewCell *)cell
               switchView:(UISwitch *)toggle {
  if (row < 0 || row >= (NSInteger)self.entries.count) return;
  ExtensionEntryModel *entry = self.entries[(NSUInteger)row];
  BOOL actual = entry.enabled;
  NSString *refreshedOptionsURL = entry.optionsPageURL;
  NSString *err = nil;
  if (SetExtensionEnabled(entry.extensionId, targetEnabled, &actual,
                          &refreshedOptionsURL, &err)) {
    entry.enabled = actual;
    entry.optionsPageURL = refreshedOptionsURL;
    self.statusError = nil;
    if (toggle && toggle.isOn != actual) {
      [toggle setOn:actual animated:YES];
    }
    if (cell) {
      [self configureAccessoryForCell:cell
                                atRow:row
                            withEntry:entry
                       existingSwitch:toggle];
    }
  } else {
    entry.enabled = actual;
    entry.optionsPageURL = refreshedOptionsURL;
    if (toggle && toggle.isOn != actual) {
      [toggle setOn:actual animated:YES];
    }
    if (cell) {
      [self configureAccessoryForCell:cell
                                atRow:row
                            withEntry:entry
                       existingSwitch:toggle];
    }
    self.statusError = err;
    [self.tableView reloadData];
  }
}

- (void)handleExtensionSwitch:(UISwitch *)sender {
  NSInteger row = sender.tag;
  if (row < 0 || row >= (NSInteger)self.entries.count) return;
  NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
  UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
  [self applyToggleForRow:row
            targetEnabled:sender.isOn
                     cell:cell
               switchView:sender];
}

@end

static void SwizzledSettingsLoadModel(id self, SEL _cmd) {
  if (gOrigSettingsLoadModel) {
    ((void (*)(id, SEL))gOrigSettingsLoadModel)(self, _cmd);
  }
  if (![self respondsToSelector:@selector(tableViewModel)]) return;
  id<CrTableViewModel> model =
      [(id<CrSettingsTableViewController>)self tableViewModel];
  Class itemCls = NSClassFromString(@"TableViewDetailIconItem");
  if (!model || !itemCls) return;

  if (![model hasSectionForSectionIdentifier:kSettingsExtensionsSectionID]) {
    if ([model respondsToSelector:@selector(insertSectionWithIdentifier:atIndex:)]) {
      [model insertSectionWithIdentifier:kSettingsExtensionsSectionID atIndex:0];
    } else {
      [model addSectionWithIdentifier:kSettingsExtensionsSectionID];
    }
  }
  BOOL bridgeReady = ResolveExtensionManager(NULL) != nil;
  id<CrTableViewDetailIconItem> item =
      [[itemCls alloc] initWithType:kSettingsExtensionsItemType];
  [item setText:@"Extensions"];
  [item setDetailText:bridgeReady ? nil : @"Unavailable"];
  [item setIconImage:[UIImage systemImageNamed:@"puzzlepiece.extension"]];
  [item setIconTintColor:UIColor.whiteColor];
  [item setIconBackgroundColor:UIColor.systemIndigoColor];
  [item setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
  [item setAccessibilityIdentifier:@"kSettingsExtensionsCellId"];
  [model addItem:item toSectionWithIdentifier:kSettingsExtensionsSectionID];
}

static void SwizzledSettingsDidSelectRow(id self,
                                         SEL _cmd,
                                         UITableView *tableView,
                                         NSIndexPath *indexPath) {
  if ([self respondsToSelector:@selector(tableViewModel)]) {
    id<CrTableViewModel> model =
        [(id<CrSettingsTableViewController>)self tableViewModel];
    id item = [model itemAtIndexPath:indexPath];
    if ([item respondsToSelector:@selector(type)] &&
        [(id<CrTableViewDetailIconItem>)item type] == kSettingsExtensionsItemType) {
      [tableView deselectRowAtIndexPath:indexPath animated:YES];
      ExtensionsManagerViewController *vc =
          [[ExtensionsManagerViewController alloc] init];
      UINavigationController *nav = [(UIViewController *)self navigationController];
      if (nav) {
        [nav pushViewController:vc animated:YES];
      } else {
        UINavigationController *wrapped =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self presentViewController:wrapped
                                                animated:YES
                                              completion:nil];
      }
      return;
    }
  }
  if (gOrigSettingsDidSelectRow) {
    ((void (*)(id, SEL, UITableView *, NSIndexPath *))gOrigSettingsDidSelectRow)(
        self, _cmd, tableView, indexPath);
  }
}

static void InstallSettingsSwizzles(void) {
  Class settingsCls = objc_getClass("SettingsTableViewController");
  if (!settingsCls) {
    NSLog(@"EXTENSIONS_MANAGER SettingsTableViewController not found");
    return;
  }
  Method loadModel = class_getInstanceMethod(settingsCls, @selector(loadModel));
  if (loadModel) {
    gOrigSettingsLoadModel =
        method_setImplementation(loadModel, (IMP)SwizzledSettingsLoadModel);
  }
  Method didSelect = class_getInstanceMethod(
      settingsCls, @selector(tableView:didSelectRowAtIndexPath:));
  if (didSelect) {
    gOrigSettingsDidSelectRow =
        method_setImplementation(didSelect, (IMP)SwizzledSettingsDidSelectRow);
  }
  BOOL bridgeReady = ResolveExtensionManager(NULL) != nil;
#if defined(ENABLE_DIAGNOSTIC_BRIDGE) && ENABLE_DIAGNOSTIC_BRIDGE
  NSLog(@"EXTENSIONS_MANAGER v4 diagnostic installed bridge=%d", bridgeReady);
#else
  NSLog(@"EXTENSIONS_MANAGER v4 production installed bridge=%d", bridgeReady);
#endif
}

__attribute__((constructor)) static void ExtensionsManagerInit(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    InstallSettingsSwizzles();
  });
}
