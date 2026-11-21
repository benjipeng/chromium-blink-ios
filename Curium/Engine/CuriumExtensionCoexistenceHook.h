#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Installs Build 35 vtable hooks that authorize single-process extension
// resource loads, messaging, service worker lifecycle callbacks, API dispatch,
// and event listener registration against the browser-verified identity of the
// originating document or worker. Fails closed when the loaded chrome_framework
// UUID or any expected vtable slot differs.
void CuriumInstallExtensionCoexistenceHooks(void);

NS_ASSUME_NONNULL_END
