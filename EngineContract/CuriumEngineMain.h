#pragma once

#import <UIKit/UIKit.h>

@protocol CrIOSBrowserHostV1;
@protocol CrIOSExtensionManagingV1;

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Enters the engine's application loop on the main thread.
int ChromeMain(int argc, char *_Nullable *_Nonnull argv);

#ifdef __cplusplus
}
#endif

NS_SWIFT_UI_ACTOR
@protocol CrIOSShellBootstrapDelegate <NSObject>

/// Creates the scene's shell around the engine-supplied browser host.
- (UIViewController *)makeRootViewControllerForScene:(UIWindowScene *)windowScene
                                       browserHost:(id<CrIOSBrowserHostV1>)browserHost
                                  extensionManager:(nullable id<CrIOSExtensionManagingV1>)extensionManager
    NS_SWIFT_NAME(makeRootViewController(for:browserHost:extensionManager:));

@end

/// Provided by chrome_framework once it exports the bootstrap implementation.
/// Standalone previews may resolve the class by name and dispatch dynamically,
/// or supply a stub or a weak link. Importing this header does not supply it.
NS_SWIFT_UI_ACTOR
@interface CrIOSEngineBootstrap : NSObject

/// Retains the delegate until it is replaced or cleared with nil.
+ (void)registerShellBootstrapDelegate:(nullable id<CrIOSShellBootstrapDelegate>)delegate;
+ (nullable id<CrIOSShellBootstrapDelegate>)shellBootstrapDelegate;

@end

NS_ASSUME_NONNULL_END
