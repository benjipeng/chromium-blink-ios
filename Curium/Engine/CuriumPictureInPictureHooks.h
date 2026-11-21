#import <Foundation/Foundation.h>

// Installs the Picture in Picture hooks on the vendored engine's CuriumPiPBridge
// (patch 0089). Call once on the main thread before ChromeMain. Each hook verifies
// the bridge's layout and leaves the engine untouched when it differs.
void CuriumInstallPictureInPictureHooks(void);
