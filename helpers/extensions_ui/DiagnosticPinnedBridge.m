#import "CrIOSExtensionManagingV1.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

// Pinned Chrome framework identity (M159 34d81e7, patched extprobe build).
static const char kExpectedImageSuffix[] =
    "/chrome_framework.framework/chrome_framework";
static const uint8_t kExpectedUUID[16] = {
    0x4C, 0x4C, 0x44, 0xC4, 0x55, 0x55, 0x31, 0x44,
    0xA1, 0x7F, 0xF4, 0x14, 0x8F, 0xCB, 0x3B, 0xF7,
};

// Verified patch sites inside __TEXT,__text.
static const uintptr_t kPatchWebstoreFactoryOff = 0x03ce2268;
static const uint32_t kPatchWebstoreFactoryInsn = 0xd65f03c0u;  // ret
static const uintptr_t kPatchRegisterPrefsOff = 0x044c1fb0;
static const uint32_t kPatchRegisterPrefsInsn = 0x9797e260u;    // bl 0x02aba930
static const uintptr_t kPatchTrampolineOff = 0x02aba930;
static const uint32_t kPatchTrampolineInsn = 0xa9be7bfdu;       // stp x29, x30, [sp, #-0x20]!

// Verified internal C++ function offsets relative to chrome_framework base.
static const uintptr_t kOffBrowserClientGetInstance = 0x044c1ecc;
static const uintptr_t kOffGetRegisteredContextsSnapshot = 0x044c38f8;
static const uintptr_t kOffCrVectorUint64Dtor = 0x000b7500;
static const uintptr_t kOffExtensionRegistryGet = 0x03bf1a70;
static const uintptr_t kOffExtensionRegistrarGet = 0x03bee020;
static const uintptr_t kOffExtensionRegistrarIsEnabled = 0x03bf0058;
static const uintptr_t kOffExtensionRegistrarEnable = 0x03befea0;
static const uintptr_t kOffExtensionRegistrarDisable = 0x03bf0120;

// Verified Chromium object layouts.
static const size_t kOffRegistryEnabledSet = 0x08;
static const size_t kOffRegistryDisabledSet = 0x20;
static const size_t kOffSetEndNode = 0x08;
static const size_t kOffSetSize = 0x10;
static const size_t kOffTreeNodeLeft = 0x00;
static const size_t kOffTreeNodeRight = 0x08;
static const size_t kOffTreeNodeParent = 0x10;
static const size_t kOffTreeNodeKey = 0x20;
static const size_t kOffTreeNodeExtensionPtr = 0x38;
static const size_t kOffExtensionName = 0x20;
static const size_t kOffExtensionVersion = 0x1f0;

static const int32_t kDisableReasonUserAction = 1;
static NSString *const kDiagErrorDomain = @"CrIOSDiagnosticPinnedBridgeErrorDomain";

// Chromium libc++ (__Cr) 24-byte layouts (distinct from Apple __1).
typedef struct {
  union {
    struct {
      const char *data;
      size_t size;
      size_t cap_and_flag;
    } l;
    struct {
      char data[23];
      uint8_t size;
    } s;
  };
} CrString;
_Static_assert(sizeof(CrString) == 24, "CrString must be 24 bytes");

typedef struct {
  void *data;
  size_t count;
  size_t capacity;
} CrVector24;
_Static_assert(sizeof(CrVector24) == 24, "CrVector24 must be 24 bytes");

typedef struct {
  const int32_t *data;
  size_t count;
  size_t capacity;
} CrFlatSetInt;
_Static_assert(sizeof(CrFlatSetInt) == 24, "CrFlatSetInt must be 24 bytes");

typedef void *(*BrowserClientGetInstanceFn)(void);
typedef CrVector24 (*GetRegisteredContextsSnapshotFn)(void *client);
typedef void (*CrVectorUint64DtorFn)(CrVector24 *vec);
typedef void *(*ExtensionRegistryGetFn)(void *browser_context);
typedef void *(*ExtensionRegistrarGetFn)(void *browser_context);
typedef uint8_t (*IsExtensionEnabledFn)(void *registrar, const CrString *ext_id);
typedef void (*EnableExtensionFn)(void *registrar, const CrString *ext_id);
typedef void (*DisableExtensionFn)(void *registrar,
                                   const CrString *ext_id,
                                   const CrFlatSetInt *reasons);

static uintptr_t gChromeBase = 0;
static BOOL gBridgeValidated = NO;
static NSString *gValidationFailureReason = @"Not validated";

static void SetDiagError(NSError *__autoreleasing *error,
                         NSInteger code,
                         NSString *description) {
  if (error) {
    *error = [NSError
        errorWithDomain:kDiagErrorDomain
                   code:code
               userInfo:@{NSLocalizedDescriptionKey : description ?: @""}];
  }
}

static BOOL EndsWith(const char *str, const char *suffix) {
  if (!str || !suffix) return NO;
  size_t slen = strlen(str);
  size_t xlen = strlen(suffix);
  return slen >= xlen && memcmp(str + (slen - xlen), suffix, xlen) == 0;
}

static BOOL ReadMachOUUID(const struct mach_header_64 *hdr, uint8_t out_uuid[16]) {
  if (!hdr || hdr->magic != MH_MAGIC_64 || hdr->cputype != CPU_TYPE_ARM64) {
    return NO;
  }
  const uint8_t *cursor = (const uint8_t *)(hdr + 1);
  const uint8_t *limit = cursor + hdr->sizeofcmds;
  for (uint32_t i = 0; i < hdr->ncmds; i++) {
    if (cursor + sizeof(struct load_command) > limit) return NO;
    const struct load_command *lc = (const struct load_command *)cursor;
    if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > limit) {
      return NO;
    }
    if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
      const struct uuid_command *uc = (const struct uuid_command *)lc;
      memcpy(out_uuid, uc->uuid, 16);
      return YES;
    }
    cursor += lc->cmdsize;
  }
  return NO;
}

static void EnsurePinnedChromeFrameworkValidated(void) {
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    gChromeBase = 0;
    gBridgeValidated = NO;

    const struct mach_header_64 *matched_hdr = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
      const char *name = _dyld_get_image_name(i);
      if (!EndsWith(name, kExpectedImageSuffix)) continue;
      const struct mach_header_64 *hdr =
          (const struct mach_header_64 *)_dyld_get_image_header(i);
      if (!hdr) continue;
      uint8_t uuid[16] = {0};
      if (!ReadMachOUUID(hdr, uuid)) {
        gValidationFailureReason = @"chrome_framework missing LC_UUID";
        return;
      }
      if (memcmp(uuid, kExpectedUUID, 16) != 0) {
        gValidationFailureReason = @"chrome_framework LC_UUID mismatch";
        return;
      }
      matched_hdr = hdr;
      break;
    }

    if (!matched_hdr) {
      gValidationFailureReason = @"chrome_framework image not loaded";
      return;
    }

    void *chrome_main = dlsym(RTLD_DEFAULT, "ChromeMain");
    Dl_info info = {0};
    if (!chrome_main || !dladdr(chrome_main, &info) ||
        info.dli_fbase != (const void *)matched_hdr) {
      gValidationFailureReason = @"ChromeMain dladdr base mismatch";
      return;
    }

    uintptr_t base = (uintptr_t)matched_hdr;
    if (*(const uint32_t *)(base + kPatchWebstoreFactoryOff) != kPatchWebstoreFactoryInsn ||
        *(const uint32_t *)(base + kPatchRegisterPrefsOff) != kPatchRegisterPrefsInsn ||
        *(const uint32_t *)(base + kPatchTrampolineOff) != kPatchTrampolineInsn) {
      gValidationFailureReason = @"chrome_framework patch bytes mismatch";
      return;
    }

    gChromeBase = base;
    gBridgeValidated = YES;
    gValidationFailureReason = nil;
  });
  static dispatch_once_t log_once;
  dispatch_once(&log_once, ^{
    NSLog(@"EXTENSIONS_MANAGER diagnostic bridge validated=%d reason=%@",
          gBridgeValidated, gValidationFailureReason ?: @"ok");
  });
}

static CrString MakeBorrowedLongCrString(const char *utf8, size_t len) {
  CrString s;
  memset(&s, 0, sizeof(s));
  s.l.data = utf8;
  s.l.size = len;
  s.l.cap_and_flag = (len + 1) | (1ULL << 63);
  return s;
}

static NSString *NSStringFromCrString(const CrString *s) {
  if (!s) return @"";
  const char *ptr = NULL;
  size_t len = 0;
  if ((int8_t)s->s.size < 0) {
    ptr = s->l.data;
    len = s->l.size;
  } else {
    ptr = s->s.data;
    len = (size_t)s->s.size;
  }
  if (!ptr || len == 0) return @"";
  return [[NSString alloc] initWithBytes:ptr
                                  length:len
                                encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *FormatCrVersion(const uint8_t *version_ptr) {
  if (!version_ptr) return @"";
  const CrVector24 *comps = (const CrVector24 *)version_ptr;
  if (!comps->data || comps->count == 0 || comps->count > 16) return @"";
  const uint32_t *nums = (const uint32_t *)comps->data;
  NSMutableString *out = [NSMutableString string];
  for (size_t i = 0; i < comps->count; i++) {
    if (i > 0) [out appendString:@"."];
    [out appendFormat:@"%u", nums[i]];
  }
  return out;
}

static void *AcquireSingleValidBrowserContext(NSError *__autoreleasing *error) {
  if (![NSThread isMainThread]) {
    SetDiagError(error, 1, @"Diagnostic bridge must be called on the main UI thread.");
    return NULL;
  }
  EnsurePinnedChromeFrameworkValidated();
  if (!gBridgeValidated || !gChromeBase) {
    SetDiagError(error, 2, gValidationFailureReason ?: @"Invalid binary state");
    return NULL;
  }

  BrowserClientGetInstanceFn get_client =
      (BrowserClientGetInstanceFn)(gChromeBase + kOffBrowserClientGetInstance);
  GetRegisteredContextsSnapshotFn get_snapshot =
      (GetRegisteredContextsSnapshotFn)(gChromeBase + kOffGetRegisteredContextsSnapshot);
  CrVectorUint64DtorFn vec_dtor =
      (CrVectorUint64DtorFn)(gChromeBase + kOffCrVectorUint64Dtor);

  void *client = get_client();
  if (!client) {
    SetDiagError(error, 3, @"IOSExtensionsBrowserClient unavailable");
    return NULL;
  }

  CrVector24 contexts = get_snapshot(client);
  void *selected = NULL;
  if (contexts.count == 1 && contexts.data != NULL) {
    selected = ((void *const *)contexts.data)[0];
  } else {
    SetDiagError(error, 4,
                 [NSString stringWithFormat:@"Expected 1 registered context, found %zu",
                                            contexts.count]);
  }
  vec_dtor(&contexts);
  if (!selected && error && !*error) {
    SetDiagError(error, 4, @"Registered BrowserContext is null");
  }
  return selected;
}

static void AppendExtensionSet(const uint8_t *ext_set,
                               NSMutableArray<NSMutableDictionary<NSString *, id> *> *outList) {
  if (!ext_set) return;
  uintptr_t node = *(const uintptr_t *)ext_set;
  uintptr_t end = (uintptr_t)(ext_set + kOffSetEndNode);
  size_t reported_size = *(const size_t *)(ext_set + kOffSetSize);

  for (size_t step = 0; step < reported_size && node != end && node != 0; step++) {
    const CrString *id_str = (const CrString *)(node + kOffTreeNodeKey);
    const uint8_t *ext = *(const uint8_t *const *)(node + kOffTreeNodeExtensionPtr);

    NSString *extId = NSStringFromCrString(id_str);
    if (extId.length > 0) {
      NSString *name = ext ? NSStringFromCrString((const CrString *)(ext + kOffExtensionName)) : @"";
      NSString *version = ext ? FormatCrVersion(ext + kOffExtensionVersion) : @"";
      [outList addObject:[@{
        @"id" : [extId copy],
        @"name" : [name copy],
        @"version" : [version copy],
        @"enabled" : @NO,
      } mutableCopy]];
    }

    uintptr_t right = *(const uintptr_t *)(node + kOffTreeNodeRight);
    if (right != 0) {
      node = right;
      while (*(const uintptr_t *)(node + kOffTreeNodeLeft) != 0) {
        node = *(const uintptr_t *)(node + kOffTreeNodeLeft);
      }
    } else {
      uintptr_t parent = *(const uintptr_t *)(node + kOffTreeNodeParent);
      while (parent != 0 && *(const uintptr_t *)(parent + kOffTreeNodeLeft) != node) {
        node = parent;
        parent = *(const uintptr_t *)(node + kOffTreeNodeParent);
      }
      node = parent;
    }
  }
}

@interface CrIOSDiagnosticPinnedExtensionManager : NSObject <CrIOSExtensionManagingV1>
+ (instancetype)sharedManager;
@end

@implementation CrIOSDiagnosticPinnedExtensionManager

+ (instancetype)sharedManager {
  static CrIOSDiagnosticPinnedExtensionManager *instance = nil;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

- (NSArray<NSDictionary<NSString *, id> *> *)extensionsWithError:
    (NSError *__autoreleasing *)error {
  void *ctx = AcquireSingleValidBrowserContext(error);
  if (!ctx) return nil;

  ExtensionRegistryGetFn registry_get =
      (ExtensionRegistryGetFn)(gChromeBase + kOffExtensionRegistryGet);
  ExtensionRegistrarGetFn registrar_get =
      (ExtensionRegistrarGetFn)(gChromeBase + kOffExtensionRegistrarGet);
  IsExtensionEnabledFn is_enabled_fn =
      (IsExtensionEnabledFn)(gChromeBase + kOffExtensionRegistrarIsEnabled);

  const uint8_t *registry = (const uint8_t *)registry_get(ctx);
  void *registrar = registrar_get(ctx);
  if (!registry || !registrar) {
    SetDiagError(error, 5, @"ExtensionRegistry or ExtensionRegistrar unavailable");
    return nil;
  }

  NSMutableArray<NSMutableDictionary<NSString *, id> *> *mutableItems =
      [NSMutableArray array];
  AppendExtensionSet(registry + kOffRegistryEnabledSet, mutableItems);
  AppendExtensionSet(registry + kOffRegistryDisabledSet, mutableItems);

  NSMutableArray<NSDictionary<NSString *, id> *> *items =
      [NSMutableArray arrayWithCapacity:mutableItems.count];
  for (NSMutableDictionary<NSString *, id> *dict in mutableItems) {
    NSString *extId = dict[@"id"];
    const char *utf8 = extId.UTF8String;
    BOOL enabled = NO;
    if (utf8) {
      CrString cr_id = MakeBorrowedLongCrString(utf8, strlen(utf8));
      enabled = is_enabled_fn(registrar, &cr_id) != 0;
    }
    dict[@"enabled"] = @(enabled);
    [items addObject:[dict copy]];
  }
  return [items copy];
}

- (BOOL)setExtensionWithID:(NSString *)extensionId
                   enabled:(BOOL)enabled
                     error:(NSError *__autoreleasing *)error {
  if (![extensionId isKindOfClass:NSString.class] || extensionId.length == 0) {
    SetDiagError(error, 6, @"Extension ID must be a non-empty string.");
    return NO;
  }
  void *ctx = AcquireSingleValidBrowserContext(error);
  if (!ctx) return NO;

  ExtensionRegistryGetFn registry_get =
      (ExtensionRegistryGetFn)(gChromeBase + kOffExtensionRegistryGet);
  ExtensionRegistrarGetFn registrar_get =
      (ExtensionRegistrarGetFn)(gChromeBase + kOffExtensionRegistrarGet);
  IsExtensionEnabledFn is_enabled_fn =
      (IsExtensionEnabledFn)(gChromeBase + kOffExtensionRegistrarIsEnabled);
  EnableExtensionFn enable_fn =
      (EnableExtensionFn)(gChromeBase + kOffExtensionRegistrarEnable);
  DisableExtensionFn disable_fn =
      (DisableExtensionFn)(gChromeBase + kOffExtensionRegistrarDisable);

  const uint8_t *registry = (const uint8_t *)registry_get(ctx);
  void *registrar = registrar_get(ctx);
  if (!registry || !registrar) {
    SetDiagError(error, 5, @"ExtensionRegistry or ExtensionRegistrar unavailable");
    return NO;
  }

  NSMutableArray<NSMutableDictionary<NSString *, id> *> *installed =
      [NSMutableArray array];
  AppendExtensionSet(registry + kOffRegistryEnabledSet, installed);
  AppendExtensionSet(registry + kOffRegistryDisabledSet, installed);
  BOOL found = NO;
  for (NSDictionary<NSString *, id> *dict in installed) {
    if ([dict[@"id"] isEqualToString:extensionId]) {
      found = YES;
      break;
    }
  }
  if (!found) {
    SetDiagError(error, 7, @"Extension is not installed in the active context.");
    return NO;
  }

  const char *utf8 = extensionId.UTF8String;
  if (!utf8) {
    SetDiagError(error, 6, @"Extension ID UTF-8 conversion failed.");
    return NO;
  }
  CrString cr_id = MakeBorrowedLongCrString(utf8, strlen(utf8));
  if (enabled) {
    enable_fn(registrar, &cr_id);
  } else {
    int32_t reason = kDisableReasonUserAction;
    CrFlatSetInt reasons = {&reason, 1, 1};
    disable_fn(registrar, &cr_id, &reasons);
  }

  BOOL actual = is_enabled_fn(registrar, &cr_id) != 0;
  if (actual != (enabled ? YES : NO)) {
    SetDiagError(error, 9,
                 enabled ? @"Extension could not be enabled."
                         : @"Extension could not be disabled.");
    return NO;
  }
  return YES;
}

@end
