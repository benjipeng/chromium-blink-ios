#import "CuriumRuntime.h"
#import "CuriumExtensionCoexistenceHook.h"
#import "CuriumHookSupport.h"
#import "CuriumInputAccessoryHook.h"
#import "CuriumPictureInPictureHooks.h"
#import "CuriumTouchCancelHook.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <os/proc.h>
#import <UIKit/UIKit.h>

static os_unfair_lock gCuriumHookStatusLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSDictionary<NSString *, NSString *> *> *gCuriumHookStatuses = nil;

void CuriumRecordHookStatus(NSString *name, NSString *status, NSString *detail) {
    NSString *safeName = name.length > 0 ? [name copy] : @"unknown";
    NSString *safeStatus = status.length > 0 ? [status copy] : @"failed";
    NSString *safeDetail = detail ? [detail copy] : @"";
    NSDictionary<NSString *, NSString *> *entry = @{
        @"name": safeName,
        @"status": safeStatus,
        @"detail": safeDetail,
    };
    os_unfair_lock_lock(&gCuriumHookStatusLock);
    if (!gCuriumHookStatuses) {
        gCuriumHookStatuses = [NSMutableArray arrayWithCapacity:10];
    }
    NSUInteger existingIndex = NSNotFound;
    for (NSUInteger i = 0; i < gCuriumHookStatuses.count; i++) {
        if ([gCuriumHookStatuses[i][@"name"] isEqualToString:safeName]) {
            existingIndex = i;
            break;
        }
    }
    if (existingIndex != NSNotFound) {
        gCuriumHookStatuses[existingIndex] = entry;
    } else {
        [gCuriumHookStatuses addObject:entry];
    }
    os_unfair_lock_unlock(&gCuriumHookStatusLock);
}

NSArray<NSDictionary<NSString *, NSString *> *> *CuriumRuntimeHookStatuses(void) {
    os_unfair_lock_lock(&gCuriumHookStatusLock);
    NSArray<NSDictionary<NSString *, NSString *> *> *snapshot =
        gCuriumHookStatuses ? [gCuriumHookStatuses copy] : @[];
    os_unfair_lock_unlock(&gCuriumHookStatusLock);
    return snapshot;
}

static void CuriumRunOnMain(dispatch_block_t block) {
    if (!block) {
        return;
    }
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static void CuriumNoOpLogLaunchMetrics(id self, SEL _cmd, id startupInfo, NSArray *scenes) {
    // Launch metrics walk Chrome's tab model for UMA that Curium never uploads.
    // Skipping them also covers engines older than build 32, whose headless
    // shell has no inactive browser for this method to dereference.
    (void)self;
    (void)_cmd;
    (void)startupInfo;
    (void)scenes;
}

static NSArray<NSString *> *gCuriumAugmentedArguments = nil;

// Adds a bare switch once.
static BOOL CuriumAddSwitch(NSMutableArray<NSString *> *args, NSString *flag) {
    if ([args containsObject:flag]) {
        return NO;
    }
    [args addObject:flag];
    return YES;
}

// Appends |items| to a list-valued switch such as --disable-features. Chromium
// keeps only the last occurrence of a switch, so a second copy would silently
// drop the first one's items.
static BOOL CuriumMergeListSwitch(NSMutableArray<NSString *> *args, NSString *name,
                                  NSString *separator, NSString *items) {
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSUInteger i = 0; i < args.count; i++) {
        if ([args[i] hasPrefix:prefix]) {
            NSString *value = [args[i] substringFromIndex:prefix.length];
            args[i] = value.length
                ? [NSString stringWithFormat:@"%@%@%@%@", prefix, value, separator, items]
                : [prefix stringByAppendingString:items];
            return YES;
        }
    }
    [args addObject:[prefix stringByAppendingString:items]];
    return YES;
}

// Builds the engine's command line once. Inputs from NSBundle and NSUserDefaults
// are read BEFORE swizzling -[NSProcessInfo arguments] so initializing Foundation's
// NSArgumentDomain can never re-enter a dispatch_once lock on the main thread.
static NSArray<NSString *> *CuriumBuildArguments(NSArray<NSString *> *base,
                                                 BOOL supportsDisableSync,
                                                 NSString *_Nullable jitPref) {
    NSMutableArray<NSString *> *args = [base mutableCopy];
    BOOL changed = NO;

#if TARGET_OS_SIMULATOR
    // Simulator's MTLSimDevice fails to compile certain complex Skia Graphite/Dawn
    // shaders and hits a fatal CHECK in GraphiteSharedContext; selecting Ganesh/Metal
    // keeps Simulator rendering stable.
    changed |= CuriumAddSwitch(args, @"--disable-skia-graphite");
    changed |= CuriumMergeListSwitch(args, @"--disable-features", @",", @"SkiaGraphite");
#endif

    // Keep the engine from contacting Google unprompted: AI Mode eligibility
    // (www.google.com/async/folae) and the translate ranker stay off.
    changed |= CuriumMergeListSwitch(args, @"--disable-features", @",",
        @"AimEnabled,AimServerEligibilityEnabled,AimServerRequestOnStartupEnabled,"
        @"TranslateRankerQuery,TranslateRankerEnforcement");

    // Enable only after vendoring an engine with patch 0096. Build 32
    // dereferences a missing SyncService at launch with this switch.
    if (supportsDisableSync) {
        changed |= CuriumAddSwitch(args, @"--disable-sync");
    }

    if ([jitPref isEqualToString:@"jitless"]) {
        changed |= CuriumAddSwitch(args, @"--curium-disable-jit");
    } else if ([jitPref isEqualToString:@"forceJIT"]) {
        changed |= CuriumAddSwitch(args, @"--curium-enable-jit");
    }

    return changed ? [args copy] : base;
}

static NSArray<NSString *> *CuriumAugmentedProcessArguments(id self, SEL _cmd) {
    // IOSChromeMain initializes base::CommandLine from NSProcessInfo.processInfo.arguments
    // rather than ChromeMain(argc, argv).
    (void)self;
    (void)_cmd;
    return gCuriumAugmentedArguments ?: @[];
}

static void CuriumInstallCommandLineGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        NSArray<NSString *> *base = [processInfo arguments] ?: @[];
        BOOL supportsDisableSync =
            [[NSBundle mainBundle].infoDictionary[@"CuriumEngineSupportsDisableSync"] boolValue];
        NSString *jitPref =
            [[[NSUserDefaults standardUserDefaults] stringForKey:@"curium.jitMode"] copy];
        gCuriumAugmentedArguments = CuriumBuildArguments(base, supportsDisableSync, jitPref);

        Class cls = object_getClass(processInfo);
        SEL sel = @selector(arguments);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) {
            CuriumRecordHookStatus(@"Command-Line Guard", @"failed",
                                   @"NSProcessInfo arguments method missing");
            return;
        }
        if (!class_addMethod(cls, sel, (IMP)CuriumAugmentedProcessArguments,
                             method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)CuriumAugmentedProcessArguments);
        }
        NSString *detail = [NSString stringWithFormat:@"%lu args (disable-sync=%d, jit=%@)",
                            (unsigned long)gCuriumAugmentedArguments.count,
                            supportsDisableSync ? 1 : 0,
                            jitPref.length > 0 ? jitPref : @"automatic"];
        CuriumRecordHookStatus(@"Command-Line Guard", @"active", detail);
    });
}

static void CuriumInstallHeadlessRuntimeGuards(void) {
    CuriumInstallCommandLineGuard();
    CuriumInstallExtensionCoexistenceHooks();
    CuriumInstallPictureInPictureHooks();
    CuriumInstallInputAccessoryHook();
    CuriumInstallTouchCancelHook();
    Class metricsMediator = NSClassFromString(@"MetricsMediator");
    if (!metricsMediator) {
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"skipped",
                               @"MetricsMediator class not present");
        return;
    }
    SEL logLaunch = NSSelectorFromString(@"logLaunchMetricsWithStartupInformation:connectedScenes:");
    Method method = class_getClassMethod(metricsMediator, logLaunch);
    if (method) {
        method_setImplementation(method, (IMP)CuriumNoOpLogLaunchMetrics);
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"active",
                               @"Suppressed Chrome launch UMA walk");
    } else {
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"skipped",
                               @"Launch metrics selector not present");
    }
}

void CuriumSetDesktopSite(id<CrIOSTabHostingV1> tab, BOOL enabled) {
    [tab setUsesDesktopUserAgent:enabled];
}

void CuriumSetPageZoom(id<CrIOSTabHostingV1> tab, CGFloat scale) {
    if ([tab respondsToSelector:@selector(setPageZoomScale:)]) {
        [tab setPageZoomScale:scale];
    }
}

uint64_t CuriumAvailableMemoryBytes(void) {
    return os_proc_available_memory();
}

NSInteger CuriumActiveV8JitMode(void) {
    typedef int (*V8JitModeFn)(void);
    static V8JitModeFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *fwPath = [[[NSBundle mainBundle] privateFrameworksPath]
            stringByAppendingPathComponent:@"chrome_framework.framework/chrome_framework"];
        if (fwPath.length > 0) {
            void *handle = dlopen(fwPath.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY);
            if (handle) {
                fn = (V8JitModeFn)dlsym(handle, "V8IOSJitGetActiveMode");
            }
        }
        if (!fn) {
            fn = (V8JitModeFn)dlsym(RTLD_DEFAULT, "V8IOSJitGetActiveMode");
        }
    });
    return fn ? (NSInteger)fn() : 0;
}

BOOL CuriumRegisterShell(id<CrIOSShellBootstrapDelegate> delegate) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(registerShellBootstrapDelegate:)]) {
        return NO;
    }
    CuriumInstallHeadlessRuntimeGuards();
    [(id)bootstrap registerShellBootstrapDelegate:delegate];
    return YES;
}

id<CrIOSExtensionManagingV1> CuriumSharedExtensionManager(void) {
    Class manager = NSClassFromString(@"CrIOSExtensionManagerV1");
    if (![manager respondsToSelector:@selector(sharedManager)]) {
        return nil;
    }
    return [(id)manager sharedManager];
}

static NSError *CuriumUnsupported(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:NSFeatureUnsupportedError
                           userInfo:@{NSLocalizedDescriptionKey:
                                          @"This feature is unavailable in the current Blink build."}];
}

void CuriumPrepareExtension(id<CrIOSExtensionManagingV1> manager, NSString *source,
                            BOOL isStore, CuriumExtensionResult completion) {
    if (!completion) {
        return;
    }
    CuriumExtensionResult safeCompletion = ^(NSDictionary<NSString *, id> *result, NSError *error) {
        CuriumRunOnMain(^{
            completion(result, error);
        });
    };
    if (![manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)] ||
        ![manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        safeCompletion(nil, CuriumUnsupported());
    } else if (isStore && [manager respondsToSelector:@selector(prepareStoreExtensionWithID:completion:)]) {
        [manager prepareStoreExtensionWithID:source completion:safeCompletion];
    } else if (!isStore && [manager respondsToSelector:@selector(prepareSignedExtensionAtPath:completion:)]) {
        [manager prepareSignedExtensionAtPath:source completion:safeCompletion];
    } else {
        safeCompletion(nil, CuriumUnsupported());
    }
}

void CuriumConfirmExtension(id<CrIOSExtensionManagingV1> manager, NSString *token,
                            CuriumExtensionResult completion) {
    if (!completion) {
        return;
    }
    CuriumExtensionResult safeCompletion = ^(NSDictionary<NSString *, id> *result, NSError *error) {
        CuriumRunOnMain(^{
            completion(result, error);
        });
    };
    if ([manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)]) {
        [manager confirmPreparedExtensionWithToken:token completion:safeCompletion];
    } else {
        safeCompletion(nil, CuriumUnsupported());
    }
}

void CuriumCancelExtension(id<CrIOSExtensionManagingV1> manager, NSString *token) {
    if ([manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        [manager cancelPreparedExtensionWithToken:token error:nil];
    }
}

void CuriumRemoveExtension(id<CrIOSExtensionManagingV1> manager, NSString *identifier,
                           void (^completion)(BOOL, NSError *)) {
    if (!completion) {
        return;
    }
    void (^safeCompletion)(BOOL, NSError *) = ^(BOOL removed, NSError *error) {
        CuriumRunOnMain(^{
            completion(removed, error);
        });
    };
    if ([manager respondsToSelector:@selector(uninstallExtensionWithID:completion:)]) {
        [manager uninstallExtensionWithID:identifier completion:safeCompletion];
    } else {
        safeCompletion(NO, CuriumUnsupported());
    }
}

NSDictionary<NSString *, id> *CuriumExtensionAction(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID) {
    if (![manager respondsToSelector:@selector(actionPresentationForExtensionWithID:tabID:error:)]) {
        return nil;
    }
    return [manager actionPresentationForExtensionWithID:identifier tabID:tabID error:nil];
}

NSNumber *_Nullable CuriumExtensionBlockedCount(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID) {
    if (![manager respondsToSelector:@selector(blockedRequestCountForExtensionWithID:tabID:error:)]) {
        return nil;
    }
    return [manager blockedRequestCountForExtensionWithID:identifier tabID:tabID error:nil];
}

id<CrIOSExtensionPopupHostingV1> CuriumExtensionPopup(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID, NSError **error) {
    if (![manager respondsToSelector:@selector(popupForExtensionWithID:tabID:error:)]) {
        if (error) *error = CuriumUnsupported();
        return nil;
    }
    return [manager popupForExtensionWithID:identifier tabID:tabID error:error];
}
