#import "CuriumRuntime.h"
#import "CuriumExtensionCoexistenceHook.h"
#import "CuriumInputAccessoryHook.h"
#import "CuriumPictureInPictureHooks.h"
#import "CuriumTouchCancelHook.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <os/proc.h>
#import <UIKit/UIKit.h>

static void CuriumNoOpLogLaunchMetrics(id self, SEL _cmd, id startupInfo, NSArray *scenes) {
    // Launch metrics walk Chrome's tab model for UMA that Curium never uploads.
    // Skipping them also covers engines older than build 32, whose headless
    // shell has no inactive browser for this method to dereference.
    (void)self;
    (void)_cmd;
    (void)startupInfo;
    (void)scenes;
}

static NSArray<NSString *> *(*gCuriumOrigProcessArguments)(id, SEL) = NULL;

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

// Builds the engine's command line once. NSProcessInfo.arguments is read
// repeatedly during startup, and the result cannot change within a launch.
static NSArray<NSString *> *CuriumBuildArguments(NSArray<NSString *> *base) {
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
    if ([[NSBundle mainBundle].infoDictionary[@"CuriumEngineSupportsDisableSync"] boolValue]) {
        changed |= CuriumAddSwitch(args, @"--disable-sync");
    }

    NSString *jitPref = [[NSUserDefaults standardUserDefaults] stringForKey:@"curium.jitMode"];
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
    static NSArray<NSString *> *arguments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *base = gCuriumOrigProcessArguments
            ? gCuriumOrigProcessArguments(self, _cmd)
            : @[];
        arguments = CuriumBuildArguments(base);
    });
    return arguments;
}

static void CuriumInstallCommandLineGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = object_getClass([NSProcessInfo processInfo]);
        SEL sel = @selector(arguments);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) {
            return;
        }
        gCuriumOrigProcessArguments =
            (NSArray<NSString *> *(*)(id, SEL))method_getImplementation(method);
        if (!class_addMethod(cls, sel, (IMP)CuriumAugmentedProcessArguments,
                             method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)CuriumAugmentedProcessArguments);
        }
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
        return;
    }
    SEL logLaunch = NSSelectorFromString(@"logLaunchMetricsWithStartupInformation:connectedScenes:");
    Method method = class_getClassMethod(metricsMediator, logLaunch);
    if (method) {
        method_setImplementation(method, (IMP)CuriumNoOpLogLaunchMetrics);
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
    if (![manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)] ||
        ![manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        completion(nil, CuriumUnsupported());
    } else if (isStore && [manager respondsToSelector:@selector(prepareStoreExtensionWithID:completion:)]) {
        [manager prepareStoreExtensionWithID:source completion:completion];
    } else if (!isStore && [manager respondsToSelector:@selector(prepareSignedExtensionAtPath:completion:)]) {
        [manager prepareSignedExtensionAtPath:source completion:completion];
    } else {
        completion(nil, CuriumUnsupported());
    }
}

void CuriumConfirmExtension(id<CrIOSExtensionManagingV1> manager, NSString *token,
                            CuriumExtensionResult completion) {
    if ([manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)]) {
        [manager confirmPreparedExtensionWithToken:token completion:completion];
    } else {
        completion(nil, CuriumUnsupported());
    }
}

void CuriumCancelExtension(id<CrIOSExtensionManagingV1> manager, NSString *token) {
    if ([manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        [manager cancelPreparedExtensionWithToken:token error:nil];
    }
}

void CuriumRemoveExtension(id<CrIOSExtensionManagingV1> manager, NSString *identifier,
                           void (^completion)(BOOL, NSError *)) {
    if ([manager respondsToSelector:@selector(uninstallExtensionWithID:completion:)]) {
        [manager uninstallExtensionWithID:identifier completion:completion];
    } else {
        completion(NO, CuriumUnsupported());
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
