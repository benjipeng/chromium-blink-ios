#import <Foundation/Foundation.h>

// Drops the engine's form accessory bar while a hardware keyboard is attached.
// Call once on the main thread before ChromeMain.
void CuriumInstallInputAccessoryHook(void);
