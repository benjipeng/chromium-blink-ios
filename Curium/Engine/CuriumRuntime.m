#import "CuriumRuntime.h"

void CuriumSetDesktopSite(id<CrIOSTabHostingV1> tab, BOOL enabled) {
    [tab setUsesDesktopUserAgent:enabled];
}

BOOL CuriumRegisterShell(id<CrIOSShellBootstrapDelegate> delegate) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(registerShellBootstrapDelegate:)]) {
        return NO;
    }
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

NSNumber *CuriumExtensionBlockedCount(
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
