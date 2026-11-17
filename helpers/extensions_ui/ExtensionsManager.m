#import "CrIOSExtensionManagingV1.h"
#import <UIKit/UIKit.h>
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
  BOOL actual = targetEnabled;
  NSArray<NSDictionary<NSString *, id> *> *latest =
      [manager extensionsWithError:nil];
  for (id obj in latest) {
    if (![obj isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *dict = (NSDictionary *)obj;
    if ([dict[@"id"] isKindOfClass:NSString.class] &&
        [(NSString *)dict[@"id"] isEqualToString:extensionId] &&
        [dict[@"enabled"] isKindOfClass:NSNumber.class]) {
      actual = [(NSNumber *)dict[@"enabled"] boolValue];
      break;
    }
  }
  if (!ok && !latest) {
    actual = !targetEnabled;
  }
  if (outActualEnabled) *outActualEnabled = actual;
  if (!ok && outError) {
    *outError = error.localizedDescription.length > 0
                    ? error.localizedDescription
                    : @"Failed to update extension state";
  }
  NSLog(@"EXTENSIONS_MANAGER toggle id=%@ target=%d actual=%d ok=%d",
        extensionId, targetEnabled, actual, ok);
  return ok;
}

@interface ExtensionsManagerViewController : UITableViewController
@property(nonatomic, copy) NSArray<ExtensionEntryModel *> *entries;
@property(nonatomic, copy) NSString *statusError;
@end

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

- (void)configureAccessibilityForCell:(UITableViewCell *)cell
                            withEntry:(ExtensionEntryModel *)entry {
  cell.isAccessibilityElement = YES;
  cell.accessibilityTraits = UIAccessibilityTraitButton;
  cell.accessibilityLabel =
      entry.version.length > 0
          ? [NSString stringWithFormat:@"%@, version %@", entry.name, entry.version]
          : entry.name;
  cell.accessibilityValue = entry.enabled ? @"Enabled" : @"Disabled";
  cell.accessibilityHint = @"Toggles extension enabled state";
  cell.accessibilityIdentifier =
      [NSString stringWithFormat:@"kExtensionCell_%@", entry.extensionId];
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
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  }

  ExtensionEntryModel *entry = self.entries[(NSUInteger)indexPath.row];
  cell.textLabel.text = entry.name;
  cell.detailTextLabel.text =
      entry.version.length > 0
          ? [NSString stringWithFormat:@"v%@  %@", entry.version, entry.extensionId]
          : entry.extensionId;

  UISwitch *toggle = [[UISwitch alloc] init];
  toggle.on = entry.enabled;
  toggle.tag = indexPath.row;
  toggle.accessibilityIdentifier =
      [NSString stringWithFormat:@"kExtensionToggle_%@", entry.extensionId];
  [toggle addTarget:self
                action:@selector(handleExtensionSwitch:)
      forControlEvents:UIControlEventValueChanged];
  cell.accessoryView = toggle;
  [self configureAccessibilityForCell:cell withEntry:entry];
  return cell;
}

- (void)applyToggleForRow:(NSInteger)row
            targetEnabled:(BOOL)targetEnabled
                     cell:(UITableViewCell *)cell
               switchView:(UISwitch *)toggle {
  if (row < 0 || row >= (NSInteger)self.entries.count) return;
  ExtensionEntryModel *entry = self.entries[(NSUInteger)row];
  BOOL actual = entry.enabled;
  NSString *err = nil;
  if (SetExtensionEnabled(entry.extensionId, targetEnabled, &actual, &err)) {
    entry.enabled = actual;
    self.statusError = nil;
    if (toggle && toggle.isOn != actual) {
      [toggle setOn:actual animated:YES];
    }
    if (cell) {
      [self configureAccessibilityForCell:cell withEntry:entry];
    }
  } else {
    entry.enabled = actual;
    if (toggle && toggle.isOn != actual) {
      [toggle setOn:actual animated:YES];
    }
    if (cell) {
      [self configureAccessibilityForCell:cell withEntry:entry];
    }
    self.statusError = err;
    [self.tableView reloadData];
  }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.entries.count == 0) return;
  NSInteger row = indexPath.row;
  if (row < 0 || row >= (NSInteger)self.entries.count) return;
  ExtensionEntryModel *entry = self.entries[(NSUInteger)row];
  UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
  UISwitch *toggle =
      [cell.accessoryView isKindOfClass:UISwitch.class]
          ? (UISwitch *)cell.accessoryView
          : nil;
  [self applyToggleForRow:row
            targetEnabled:!entry.enabled
                     cell:cell
               switchView:toggle];
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
