#import "CuriumClipboardHook.h"
#import "CuriumHookSupport.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#import <os/log.h>
#import <time.h>

#if defined(__has_include) && __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

// Upstream Blink iOS's ui::ClipboardIOS::GetAllAvailableFormats enumerates
// [[UIPasteboard generalPasteboard] items] and inserts each item dictionary's
// literal key string into its available-formats set without checking UTI
// conformance. On iOS, plain text placed on the pasteboard by UIKit, SwiftUI,
// Safari, password managers, Universal Clipboard, and simctl is stored under
// "public.utf8-plain-text", whereas ClipboardFormatType::PlainTextType()
// checks exact equality against "public.plain-text". As a result, Blink sees
// zero plain-text formats on the clipboard and aborts Editor::Paste before
// ClipboardIOS::ReadText is ever called.
//
// Second, RenderWidgetUIView -paste: dispatches handleEditCommands:{"paste"}
// asynchronously over Mojo IPC and returns immediately. By the time Blink calls
// back into ClipboardIOS on the UI thread, UIKit has ended the trusted -paste:
// action, which triggers iOS's "Allow Paste" modal prompt on physical devices.
//
// This hook solves both problems using only Objective-C runtime APIs (no engine
// UUID or offset pinning):
// - Swizzles -[RenderWidgetUIView paste:] to snapshot [UIPasteboard generalPasteboard]
//   synchronously inside UIKit's trusted paste invocation.
// - Swizzles the concrete UIPasteboard class's -items,
//   -dataForPasteboardType:inItemSet:, and -image ONLY for callers whose return
//   address lies inside chrome_framework's __TEXT segment, leaving SwiftUI,
//   UIKit, and Curium chrome completely untouched.

typedef void (*CuriumPasteIMP)(id, SEL, id _Nullable);
typedef BOOL (*CuriumCanPerformActionIMP)(id, SEL, SEL, id _Nullable);
typedef BOOL (*CuriumIsEditableIMP)(id, SEL);
typedef NSArray<NSDictionary<NSString *, id> *> *_Nullable (*CuriumPasteboardItemsIMP)(id, SEL);
typedef NSArray<NSData *> *_Nullable (*CuriumPasteboardDataIMP)(id, SEL, NSString *, NSIndexSet *_Nullable);
typedef UIImage *_Nullable (*CuriumPasteboardImageIMP)(id, SEL);

static const uint64_t kCuriumPasteSnapshotTTLNanos = 2ULL * NSEC_PER_SEC;

static CuriumPasteIMP gOrigRenderWidgetPaste;
static CuriumCanPerformActionIMP gOrigRenderWidgetCanPerformAction;
static CuriumIsEditableIMP gRenderWidgetIsEditable;

static CuriumPasteboardItemsIMP gOrigPasteboardItems;
static CuriumPasteboardDataIMP gOrigPasteboardDataForType;
static CuriumPasteboardImageIMP gOrigPasteboardImage;

static uintptr_t gChromeTextStart = 0;
static uintptr_t gChromeTextEnd = 0;

static os_unfair_lock gPasteSnapshotLock = OS_UNFAIR_LOCK_INIT;
static NSInteger gSnapshotChangeCount = NSNotFound;
static uint64_t gSnapshotExpiresNanos = 0;
static NSArray<NSDictionary<NSString *, id> *> *gSnapshotItems = nil;
static UIImage *gSnapshotImage = nil;

static os_log_t CuriumClipboardLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.appautomaton.curium", "engine");
    });
    return log;
}

static uint64_t CuriumMonotonicNanos(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static BOOL CuriumInitChromeTextBounds(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "chrome_framework.framework/chrome_framework")) {
            continue;
        }
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) {
            continue;
        }
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cmdPtr = (const uint8_t *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmdPtr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)lc;
                if (strcmp(seg->segname, "__TEXT") == 0 && seg->vmsize > 0) {
                    uintptr_t start = (uintptr_t)((intptr_t)seg->vmaddr + slide);
                    gChromeTextStart = start;
                    gChromeTextEnd = start + (uintptr_t)seg->vmsize;
                    return YES;
                }
            }
            cmdPtr += lc->cmdsize;
        }
    }
    return NO;
}

static inline BOOL CuriumIsAddressInChromeFramework(void *address) {
    uintptr_t start = gChromeTextStart;
    uintptr_t end = gChromeTextEnd;
    if (start == 0 || end <= start || !address) {
        return NO;
    }
#if defined(__PTRAUTH_INTRINSICS__)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    uintptr_t pc = (uintptr_t)address;
    return pc >= start && pc < end;
}

static NSString *_Nullable CuriumDecodePlainTextValue(id value, NSString *sourceKey) {
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSURL class]]) {
        NSString *abs = [(NSURL *)value absoluteString];
        return abs.length > 0 ? abs : nil;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)value;
        if (data.length == 0) {
            return @"";
        }
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        BOOL hasUTF16BOM = data.length >= 2 &&
            ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
             (bytes[0] == 0xFE && bytes[1] == 0xFF));
        BOOL isUTF16Type =
            [sourceKey isEqualToString:UTTypeUTF16PlainText.identifier] ||
            [sourceKey isEqualToString:UTTypeUTF16ExternalPlainText.identifier];
        if (hasUTF16BOM) {
            return [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
        }
        if (isUTF16Type) {
            return [[NSString alloc] initWithData:data
                                         encoding:NSUTF16LittleEndianStringEncoding];
        }
        // Reject binary plists when synthesizing plain text from non-text types.
        if (data.length >= 6 && memcmp(bytes, "bplist", 6) == 0) {
            return nil;
        }
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

static NSData *_Nullable CuriumDataFromPasteboardValue(id value,
                                                       NSString *sourceKey,
                                                       NSString *requestedType) {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([value isKindOfClass:[NSURL class]]) {
        NSString *abs = [(NSURL *)value absoluteString];
        return abs.length > 0 ? [abs dataUsingEncoding:NSUTF8StringEncoding] : nil;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)value;
        if ([requestedType isEqualToString:UTTypePlainText.identifier] ||
            [requestedType isEqualToString:UTTypeUTF8PlainText.identifier]) {
            const uint8_t *bytes = (const uint8_t *)data.bytes;
            BOOL hasUTF16BOM = data.length >= 2 &&
                ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                 (bytes[0] == 0xFE && bytes[1] == 0xFF));
            BOOL isUTF16Type =
                [sourceKey isEqualToString:UTTypeUTF16PlainText.identifier] ||
                [sourceKey isEqualToString:UTTypeUTF16ExternalPlainText.identifier];
            if (hasUTF16BOM || isUTF16Type) {
                NSString *decoded = CuriumDecodePlainTextValue(data, sourceKey);
                if (decoded) {
                    return [decoded dataUsingEncoding:NSUTF8StringEncoding];
                }
            }
        }
        return data;
    }
    return nil;
}

NSArray<NSDictionary<NSString *, id> *> *CuriumNormalizePasteboardItems(
    NSArray<NSDictionary<NSString *, id> *> *_Nullable rawItems) {
    if (rawItems.count == 0) {
        return @[];
    }

    NSString *plainTextID = UTTypePlainText.identifier;
    NSString *utf8PlainTextID = UTTypeUTF8PlainText.identifier;
    NSString *htmlID = UTTypeHTML.identifier;
    NSString *rtfID = UTTypeRTF.identifier;
    NSString *pngID = UTTypePNG.identifier;
    NSString *svgID = UTTypeSVG.identifier;
    NSString *imageID = UTTypeImage.identifier;

    NSMutableArray<NSDictionary<NSString *, id> *> *normalized = nil;

    for (NSUInteger idx = 0; idx < rawItems.count; idx++) {
        NSDictionary<NSString *, id> *item = rawItems[idx];
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (normalized) {
                [normalized addObject:item];
            }
            continue;
        }

        __block NSMutableDictionary<NSString *, id> *augmented = nil;
        void (^ensureMutable)(void) = ^{
            if (!augmented) {
                augmented = [item mutableCopy];
            }
        };

        // 1. Canonical plain-text alias ("public.plain-text").
        if (!item[plainTextID]) {
            id utf8Val = item[utf8PlainTextID];
            if (utf8Val) {
                NSString *decoded = CuriumDecodePlainTextValue(utf8Val, utf8PlainTextID);
                ensureMutable();
                augmented[plainTextID] = decoded ?: utf8Val;
            } else {
                NSString *matchedTextKey = nil;
                id matchedTextVal = nil;
                NSString *matchedURLKey = nil;
                id matchedURLVal = nil;
                for (id rawKey in item) {
                    if (![rawKey isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    NSString *key = (NSString *)rawKey;
                    UTType *ut = [UTType typeWithIdentifier:key];
                    if (!ut) {
                        continue;
                    }
                    if (!matchedTextKey && [ut conformsToType:UTTypePlainText]) {
                        matchedTextKey = key;
                        matchedTextVal = item[key];
                    } else if (!matchedURLKey &&
                               [ut conformsToType:UTTypeURL] &&
                               ![ut conformsToType:UTTypeFileURL]) {
                        matchedURLKey = key;
                        matchedURLVal = item[key];
                    }
                }
                if (matchedTextKey && matchedTextVal) {
                    NSString *decoded =
                        CuriumDecodePlainTextValue(matchedTextVal, matchedTextKey);
                    ensureMutable();
                    augmented[plainTextID] = decoded ?: matchedTextVal;
                } else if (matchedURLKey && matchedURLVal) {
                    NSString *urlString =
                        CuriumDecodePlainTextValue(matchedURLVal, matchedURLKey);
                    if (urlString.length > 0) {
                        ensureMutable();
                        augmented[plainTextID] = urlString;
                    }
                }
            }
        }

        // 2. Canonical aliases for HTML, RTF, PNG, SVG, and raster images.
        BOOL needHTML = (item[htmlID] == nil);
        BOOL needRTF = (item[rtfID] == nil);
        BOOL needPNG = (item[pngID] == nil);
        BOOL needSVG = (item[svgID] == nil);
        BOOL needImage = (item[imageID] == nil);

        if (needHTML || needRTF || needPNG || needSVG || needImage) {
            for (id rawKey in item) {
                if (![rawKey isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSString *key = (NSString *)rawKey;
                UTType *ut = [UTType typeWithIdentifier:key];
                if (!ut) {
                    continue;
                }
                id val = item[key];
                if (needHTML && [ut conformsToType:UTTypeHTML]) {
                    ensureMutable();
                    augmented[htmlID] = val;
                    needHTML = NO;
                }
                if (needRTF && [ut conformsToType:UTTypeRTF]) {
                    ensureMutable();
                    augmented[rtfID] = val;
                    needRTF = NO;
                }
                if (needPNG && [ut conformsToType:UTTypePNG]) {
                    ensureMutable();
                    augmented[pngID] = val;
                    needPNG = NO;
                }
                if (needSVG && [ut conformsToType:UTTypeSVG]) {
                    ensureMutable();
                    augmented[svgID] = val;
                    needSVG = NO;
                }
                if (needImage &&
                    [ut conformsToType:UTTypeImage] &&
                    ![ut conformsToType:UTTypeSVG]) {
                    ensureMutable();
                    augmented[imageID] = val;
                    needImage = NO;
                }
            }
        }

        if (augmented) {
            if (!normalized) {
                normalized = [NSMutableArray arrayWithCapacity:rawItems.count];
                for (NSUInteger prev = 0; prev < idx; prev++) {
                    [normalized addObject:rawItems[prev]];
                }
            }
            [normalized addObject:[augmented copy]];
        } else if (normalized) {
            [normalized addObject:item];
        }
    }

    return normalized ? [normalized copy] : rawItems;
}

NSArray<NSData *> *_Nullable CuriumExtractPasteboardDataForType(
    NSArray<NSDictionary<NSString *, id> *> *_Nullable items,
    NSString *pasteboardType,
    NSIndexSet *_Nullable itemSet) {
    if (items.count == 0 || pasteboardType.length == 0) {
        return nil;
    }

    UTType *requestedUT = [UTType typeWithIdentifier:pasteboardType];
    NSMutableArray<NSData *> *results = nil;

    for (NSUInteger idx = 0; idx < items.count; idx++) {
        if (itemSet && ![itemSet containsIndex:idx]) {
            continue;
        }
        NSDictionary<NSString *, id> *item = items[idx];
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *matchedKey = nil;
        id matchedVal = item[pasteboardType];
        if (matchedVal) {
            matchedKey = pasteboardType;
        } else if (requestedUT) {
            if ([requestedUT isEqual:UTTypePlainText] &&
                item[UTTypeUTF8PlainText.identifier]) {
                matchedKey = UTTypeUTF8PlainText.identifier;
                matchedVal = item[matchedKey];
            } else {
                for (id rawKey in item) {
                    if (![rawKey isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    NSString *key = (NSString *)rawKey;
                    UTType *ut = [UTType typeWithIdentifier:key];
                    if (ut && [ut conformsToType:requestedUT]) {
                        matchedKey = key;
                        matchedVal = item[key];
                        break;
                    }
                }
            }
        }

        if (!matchedKey || !matchedVal) {
            continue;
        }

        NSData *data =
            CuriumDataFromPasteboardValue(matchedVal, matchedKey, pasteboardType);
        if (data) {
            if (!results) {
                results = [NSMutableArray arrayWithCapacity:items.count];
            }
            [results addObject:data];
        }
    }

    return results.count > 0 ? [results copy] : nil;
}

static void CuriumClearPasteSnapshot(void) {
    NSArray *oldItems = nil;
    UIImage *oldImage = nil;
    os_unfair_lock_lock(&gPasteSnapshotLock);
    gSnapshotChangeCount = NSNotFound;
    gSnapshotExpiresNanos = 0;
    oldItems = gSnapshotItems;
    gSnapshotItems = nil;
    oldImage = gSnapshotImage;
    gSnapshotImage = nil;
    os_unfair_lock_unlock(&gPasteSnapshotLock);
    (void)oldItems;
    (void)oldImage;
}

static BOOL CuriumLoadActivePasteSnapshot(NSInteger currentChangeCount,
                                          NSArray<NSDictionary<NSString *, id> *> **itemsOut,
                                          UIImage **imageOut) {
    uint64_t now = CuriumMonotonicNanos();
    BOOL active = NO;
    NSArray<NSDictionary<NSString *, id> *> *items = nil;
    UIImage *image = nil;

    os_unfair_lock_lock(&gPasteSnapshotLock);
    if (gSnapshotItems &&
        gSnapshotChangeCount == currentChangeCount &&
        now < gSnapshotExpiresNanos) {
        active = YES;
        items = gSnapshotItems;
        image = gSnapshotImage;
    }
    os_unfair_lock_unlock(&gPasteSnapshotLock);

    if (itemsOut) *itemsOut = items;
    if (imageOut) *imageOut = image;
    return active;
}

static BOOL CuriumItemsHaveAnyEntries(NSArray<NSDictionary<NSString *, id> *> *_Nullable items) {
    for (NSDictionary<NSString *, id> *item in items) {
        if ([item isKindOfClass:[NSDictionary class]] && item.count > 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL CuriumItemsHaveKey(NSArray<NSDictionary<NSString *, id> *> *_Nullable items,
                               NSString *key) {
    for (NSDictionary<NSString *, id> *item in items) {
        if ([item isKindOfClass:[NSDictionary class]] && item[key] != nil) {
            return YES;
        }
    }
    return NO;
}

static void CuriumCaptureTrustedPasteSnapshot(void) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if (!pb || !gOrigPasteboardItems) {
        CuriumClearPasteSnapshot();
        return;
    }

    NSInteger changeCount = pb.changeCount;
    NSArray<NSDictionary<NSString *, id> *> *rawItems =
        gOrigPasteboardItems(pb, @selector(items));
    NSArray<NSDictionary<NSString *, id> *> *normalized =
        CuriumNormalizePasteboardItems(rawItems);

    NSString *plainTextID = UTTypePlainText.identifier;
    NSString *utf8PlainTextID = UTTypeUTF8PlainText.identifier;

    // UIPasteboard.items can return @[ @{} ] (count == 1, empty dict) or omit
    // plain text when a lazy/Handoff representation is pending. Fall back to
    // pb.string / pb.URL synchronously while UIKit's -paste: grant is active.
    if (!CuriumItemsHaveKey(normalized, plainTextID) && (pb.hasStrings || pb.hasURLs)) {
        NSString *fallbackText = pb.string;
        if (fallbackText.length == 0) {
            fallbackText = pb.URL.absoluteString;
        }
        if (fallbackText.length > 0) {
            if (CuriumItemsHaveAnyEntries(normalized)) {
                NSMutableArray<NSDictionary<NSString *, id> *> *patched =
                    [normalized mutableCopy];
                NSMutableDictionary<NSString *, id> *first =
                    [patched[0] isKindOfClass:[NSDictionary class]]
                        ? [patched[0] mutableCopy]
                        : [NSMutableDictionary dictionary];
                first[plainTextID] = fallbackText;
                if (!first[utf8PlainTextID]) {
                    first[utf8PlainTextID] = fallbackText;
                }
                patched[0] = [first copy];
                normalized = [patched copy];
            } else {
                normalized = @[@{
                    plainTextID: fallbackText,
                    utf8PlainTextID: fallbackText,
                }];
            }
        }
    }

    if (!CuriumItemsHaveAnyEntries(normalized)) {
        // Never cache an empty @[ @{} ] snapshot; let later reads retry cleanly.
        CuriumClearPasteSnapshot();
        return;
    }

    // Preload UIImage synchronously only when the pasteboard advertises a raster
    // image so ClipboardIOS::ReadPng never touches UIPasteboard after -paste: exits.
    UIImage *image = nil;
    NSString *imageID = UTTypeImage.identifier;
    NSString *pngID = UTTypePNG.identifier;
    BOOL hasRasterImage =
        CuriumItemsHaveKey(normalized, imageID) || CuriumItemsHaveKey(normalized, pngID);
    if (hasRasterImage && gOrigPasteboardImage) {
        image = gOrigPasteboardImage(pb, @selector(image));
    }

    uint64_t expires = CuriumMonotonicNanos() + kCuriumPasteSnapshotTTLNanos;
    NSArray *oldItems = nil;
    UIImage *oldImage = nil;
    os_unfair_lock_lock(&gPasteSnapshotLock);
    gSnapshotChangeCount = changeCount;
    gSnapshotExpiresNanos = expires;
    oldItems = gSnapshotItems;
    gSnapshotItems = normalized;
    oldImage = gSnapshotImage;
    gSnapshotImage = image;
    os_unfair_lock_unlock(&gPasteSnapshotLock);
    (void)oldItems;
    (void)oldImage;
}

static void CuriumRenderWidgetPaste(id self, SEL _cmd, id _Nullable sender) {
    CuriumCaptureTrustedPasteSnapshot();
    gOrigRenderWidgetPaste(self, _cmd, sender);
}

static BOOL CuriumRenderWidgetCanPerformAction(id self, SEL _cmd, SEL action,
                                               id _Nullable sender) {
    BOOL allowed = gOrigRenderWidgetCanPerformAction(self, _cmd, action, sender);
    if (!allowed &&
        action == @selector(paste:) &&
        ((UIView *)self).window != nil &&
        gRenderWidgetIsEditable &&
        gRenderWidgetIsEditable(self, @selector(isEditable))) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        if (pb.hasURLs || pb.hasImages) {
            return YES;
        }
    }
    return allowed;
}

static NSArray<NSDictionary<NSString *, id> *> *_Nullable CuriumPasteboardItems(
    id self, SEL _cmd) {
    void *caller = __builtin_return_address(0);
    if (self != [UIPasteboard generalPasteboard] ||
        !CuriumIsAddressInChromeFramework(caller)) {
        return gOrigPasteboardItems(self, _cmd);
    }

    NSInteger changeCount = [(UIPasteboard *)self changeCount];
    NSArray<NSDictionary<NSString *, id> *> *snapshotItems = nil;
    if (CuriumLoadActivePasteSnapshot(changeCount, &snapshotItems, NULL)) {
        return snapshotItems;
    }

    NSArray<NSDictionary<NSString *, id> *> *rawItems =
        gOrigPasteboardItems(self, _cmd);
    return CuriumNormalizePasteboardItems(rawItems);
}

static NSArray<NSData *> *_Nullable CuriumPasteboardDataForType(
    id self, SEL _cmd, NSString *pasteboardType, NSIndexSet *_Nullable itemSet) {
    void *caller = __builtin_return_address(0);
    if (self != [UIPasteboard generalPasteboard] ||
        !CuriumIsAddressInChromeFramework(caller)) {
        return gOrigPasteboardDataForType(self, _cmd, pasteboardType, itemSet);
    }

    NSInteger changeCount = [(UIPasteboard *)self changeCount];
    NSArray<NSDictionary<NSString *, id> *> *snapshotItems = nil;
    if (CuriumLoadActivePasteSnapshot(changeCount, &snapshotItems, NULL)) {
        NSArray<NSData *> *extracted =
            CuriumExtractPasteboardDataForType(snapshotItems, pasteboardType, itemSet);
        if (extracted) {
            return extracted;
        }
        // Only fall through to UIPasteboard if the requested type actually
        // exists in the snapshot under an unhandled value representation.
        BOOL keyPresent = NO;
        for (NSDictionary<NSString *, id> *item in snapshotItems) {
            if ([item isKindOfClass:[NSDictionary class]] && item[pasteboardType]) {
                keyPresent = YES;
                break;
            }
        }
        if (!keyPresent) {
            return nil;
        }
    }

    NSArray<NSData *> *result =
        gOrigPasteboardDataForType(self, _cmd, pasteboardType, itemSet);
    if (result.count > 0) {
        return result;
    }

    // Fallback for direct ClipboardIOS::ReadText calls (e.g. navigator.clipboard.readText())
    // when the pasteboard only contains a URL or a representation UIKit did not
    // directly return for public.plain-text.
    if (itemSet == nil &&
        [pasteboardType isEqualToString:UTTypePlainText.identifier]) {
        UIPasteboard *pb = (UIPasteboard *)self;
        NSString *fallback = pb.string;
        if (fallback.length == 0) {
            fallback = pb.URL.absoluteString;
        }
        if (fallback.length > 0) {
            NSData *utf8 = [fallback dataUsingEncoding:NSUTF8StringEncoding];
            if (utf8) {
                return @[utf8];
            }
        }
    }
    return result;
}

static UIImage *_Nullable CuriumPasteboardImage(id self, SEL _cmd) {
    void *caller = __builtin_return_address(0);
    if (self != [UIPasteboard generalPasteboard] ||
        !CuriumIsAddressInChromeFramework(caller)) {
        return gOrigPasteboardImage(self, _cmd);
    }

    NSInteger changeCount = [(UIPasteboard *)self changeCount];
    UIImage *snapshotImage = nil;
    if (CuriumLoadActivePasteSnapshot(changeCount, NULL, &snapshotImage)) {
        return snapshotImage;
    }

    return gOrigPasteboardImage(self, _cmd);
}

static BOOL CuriumInstallMethodOverride(Class cls, SEL sel,
                                        const char *expectedEncoding,
                                        IMP replacement, IMP *origOut) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return NO;
    }
    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, expectedEncoding) != 0) {
        return NO;
    }
    Class superCls = class_getSuperclass(cls);
    BOOL declaredOnClass =
        !superCls || (class_getInstanceMethod(superCls, sel) != method);
    if (declaredOnClass) {
        *origOut = method_setImplementation(method, replacement);
        return *origOut != NULL;
    }
    IMP inherited = method_getImplementation(method);
    if (!inherited || !class_addMethod(cls, sel, replacement, types)) {
        return NO;
    }
    *origOut = inherited;
    return YES;
}

void CuriumInstallClipboardHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        os_log_t log = CuriumClipboardLog();
        Class renderViewCls = NSClassFromString(@"RenderWidgetUIView");
        if (!renderViewCls) {
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"skipped",
                                   @"RenderWidgetUIView class not present");
            return;
        }
        if (!CuriumInitChromeTextBounds()) {
            os_log_error(log, "clipboard hook: skipped, chrome_framework __TEXT not found");
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"failed",
                                   @"chrome_framework __TEXT bounds unavailable");
            return;
        }

        Method mPaste = CuriumExpectMethod(renderViewCls, "paste:", "v24@0:8@16");
        if (!mPaste) {
            os_log_error(log, "clipboard hook: skipped, unexpected RenderWidgetUIView paste:");
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"failed",
                                   @"Unexpected RenderWidgetUIView paste: layout");
            return;
        }

        UIPasteboard *generalPB = [UIPasteboard generalPasteboard];
        Class pbCls = generalPB ? object_getClass(generalPB) : Nil;
        if (!pbCls) {
            os_log_error(log, "clipboard hook: skipped, generalPasteboard unavailable");
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"failed",
                                   @"UIPasteboard generalPasteboard unavailable");
            return;
        }

        // Validate all UIPasteboard method signatures before mutating any IMP so
        // failure stays strictly fail-closed.
        Method mItems = class_getInstanceMethod(pbCls, @selector(items));
        Method mData = class_getInstanceMethod(pbCls, @selector(dataForPasteboardType:inItemSet:));
        Method mImage = class_getInstanceMethod(pbCls, @selector(image));
        const char *tItems = mItems ? method_getTypeEncoding(mItems) : NULL;
        const char *tData = mData ? method_getTypeEncoding(mData) : NULL;
        const char *tImage = mImage ? method_getTypeEncoding(mImage) : NULL;

        if (!tItems || strcmp(tItems, "@16@0:8") != 0 ||
            !tData || strcmp(tData, "@32@0:8@16@24") != 0 ||
            !tImage || strcmp(tImage, "@16@0:8") != 0) {
            os_log_error(log,
                         "clipboard hook: skipped, unexpected %@ encodings (items=%{public}s data=%{public}s image=%{public}s)",
                         NSStringFromClass(pbCls),
                         tItems ?: "nil", tData ?: "nil", tImage ?: "nil");
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"failed",
                                   @"Unexpected UIPasteboard method encodings");
            return;
        }

        IMP origItems = NULL;
        IMP origData = NULL;
        IMP origImage = NULL;
        if (!CuriumInstallMethodOverride(pbCls, @selector(items), "@16@0:8",
                                         (IMP)CuriumPasteboardItems, &origItems) ||
            !CuriumInstallMethodOverride(pbCls, @selector(dataForPasteboardType:inItemSet:),
                                         "@32@0:8@16@24",
                                         (IMP)CuriumPasteboardDataForType, &origData) ||
            !CuriumInstallMethodOverride(pbCls, @selector(image), "@16@0:8",
                                         (IMP)CuriumPasteboardImage, &origImage)) {
            os_log_error(log, "clipboard hook: failed to override UIPasteboard methods");
            CuriumRecordHookStatus(@"Clipboard Paste Guard", @"failed",
                                   @"Failed to swizzle UIPasteboard methods");
            return;
        }
        gOrigPasteboardItems = (CuriumPasteboardItemsIMP)origItems;
        gOrigPasteboardDataForType = (CuriumPasteboardDataIMP)origData;
        gOrigPasteboardImage = (CuriumPasteboardImageIMP)origImage;

        gOrigRenderWidgetPaste = (CuriumPasteIMP)method_setImplementation(
            mPaste, (IMP)CuriumRenderWidgetPaste);

        // Optional enhancement: allow Paste menu for bare URLs / images when the
        // focused element is editable.
        Method mCanPerform = CuriumExpectMethod(renderViewCls,
                                                "canPerformAction:withSender:",
                                                "B32@0:8:16@24");
        Method mIsEditable = CuriumExpectMethod(renderViewCls, "isEditable", "B16@0:8");
        if (mCanPerform && mIsEditable) {
            gRenderWidgetIsEditable = (CuriumIsEditableIMP)method_getImplementation(mIsEditable);
            gOrigRenderWidgetCanPerformAction =
                (CuriumCanPerformActionIMP)method_setImplementation(
                    mCanPerform, (IMP)CuriumRenderWidgetCanPerformAction);
        }

        os_log(log, "clipboard hook: installed on RenderWidgetUIView + %{public}@",
               NSStringFromClass(pbCls));
        CuriumRecordHookStatus(@"Clipboard Paste Guard", @"active",
                               [NSString stringWithFormat:@"UTI conformance + trusted paste snapshot (%@)",
                                NSStringFromClass(pbCls)]);
    });
}
