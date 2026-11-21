#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Fixes Blink iOS paste in two layers without pinning engine offsets:
// 1. Normalizes UIPasteboard item dictionaries for chrome_framework so
//    ClipboardIOS::GetAllAvailableFormats (which matches exact UTI strings)
//    sees canonical UTIs such as public.plain-text when iOS exposes conforming
//    subtypes such as public.utf8-plain-text.
// 2. Snapshots the general pasteboard synchronously inside
//    -[RenderWidgetUIView paste:] (UIKit's trusted paste invocation) and serves
//    Blink's subsequent async Mojo clipboard reads from that short-lived,
//    changeCount-validated snapshot so iOS does not prompt for paste permission
//    after -paste: returns.
void CuriumInstallClipboardHook(void);

// Pure helpers exposed for unit testing.
NSArray<NSDictionary<NSString *, id> *> *CuriumNormalizePasteboardItems(
    NSArray<NSDictionary<NSString *, id> *> *_Nullable rawItems);

NSArray<NSData *> *_Nullable CuriumExtractPasteboardDataForType(
    NSArray<NSDictionary<NSString *, id> *> *_Nullable items,
    NSString *pasteboardType,
    NSIndexSet *_Nullable itemSet);

NS_ASSUME_NONNULL_END
