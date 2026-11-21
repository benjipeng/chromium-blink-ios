#import "CuriumExtensionCoexistenceHook.h"
#import "CuriumHookSupport.h"

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdbool.h>
#import <stddef.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>

// In single-process Blink on iOS, every renderer document and service worker
// shares one RenderProcessHost ID, while extensions::ProcessMap stores at most
// one ExtensionId per process ID. Whichever extension claims the slot first
// locks every other enabled extension out of private resource loads, MV3
// service worker registration, extension messaging (triggering
// EMF_INVALID_MESSAGE_FROM_SANDBOXED_PROCESS -> ShutdownForBadMessage),
// privileged API dispatch, and event listener registration — and also lets
// unrelated documents in the shared process hit the ProcessMap shortcut for
// the winning extension's private resources.
//
// This hook patches only __DATA_CONST vtable slots in Build 35's
// chrome_framework (never __TEXT), pinned by LC_UUID and exact expected target
// pointers. At each browser entry point on the UI thread, it verifies the
// browser-owned origin or worker identity and scopes ProcessMap strictly to
// that identity (or hides ProcessMap entirely for non-extension / sandboxed
// contexts) for the synchronous duration of the call. ProcessMap is never
// broadened globally, and bad-message shutdown stays fully armed.

#if defined(__arm64__)

static os_log_t CuriumExtHookLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.appautomaton.curium", "engine");
    });
    return log;
}

#pragma mark - Build 35 verified offsets (UUID 4C4C4483-5555-3144-A14F-B2F89F30C28A)

static const uint8_t kBuild35UUID[16] = {
    0x4c, 0x4c, 0x44, 0x83, 0x55, 0x55, 0x31, 0x44,
    0xa1, 0x4f, 0xb2, 0xf8, 0x9f, 0x30, 0xc2, 0x8a,
};

// Direct helper addresses (file offsets in chrome_framework __TEXT).
static const uintptr_t kFnOriginDtor                           = 0x00009070;
static const uintptr_t kFnOperatorDeleteSized                  = 0x0000a040;
static const uintptr_t kFnPendingRemoteDtor                    = 0x000503f0;
static const uintptr_t kFnExtensionId                          = 0x0021cd78;
static const uintptr_t kFnExtensionRegistryGet                 = 0x002f07a0;
static const uintptr_t kFnOriginCopyCtor                       = 0x004d5b68;
static const uintptr_t kFnRenderProcessHostFromID              = 0x0050e118;
static const uintptr_t kFnExtensionURLLoaderFactoryCreate      = 0x00fcf470;
static const uintptr_t kFnFactoriesMapEmplace                  = 0x0100c830;
static const uintptr_t kFnProcessManagerGet                    = 0x010549d0;
static const uintptr_t kFnProcessMapGet                        = 0x01242828;
static const uintptr_t kFnExtensionSetGetByID                  = 0x013520ac;
static const uintptr_t kFnWeakUIWindowFromUIWindow             = 0x040d4710;
static const uintptr_t kFnInstallPromptDataDtor                = 0x06b228f8;
static const uintptr_t kFnProcessManagerHasServiceWorker       = 0x06b2c254;
static const uintptr_t kFnProcessManagerHasServiceWorkerForExt = 0x06b2c25c;
static const uintptr_t kFnServiceWorkerTaskQueueGet            = 0x06b394dc;
static const uintptr_t kFnServiceWorkerTaskQueueIsCurrentAct   = 0x06b396dc;

// Vtable slot file offsets in chrome_framework __DATA_CONST,__const and their
// expected original function targets.
static const uintptr_t kSlotRegisterSubresourceFactories = 0x0b173480;
static const uintptr_t kOrigRegisterSubresourceFactories = 0x02c762c8;

static const uintptr_t kSlotFactoryCreateLoaderAndStart  = 0x0b276c08;
static const uintptr_t kOrigFactoryCreateLoaderAndStart  = 0x06b16f8c;

static const uintptr_t kSlotFrameHostRequest             = 0x0b275038;
static const uintptr_t kOrigFrameHostRequest             = 0x0124197c;

static const uintptr_t kSlotFrameHostOpenChannelToExt    = 0x0b275078;
static const uintptr_t kOrigFrameHostOpenChannelToExt    = 0x06b0b6c0;

static const uintptr_t kSlotFrameHostOpenChannelToNative = 0x0b275080;
static const uintptr_t kOrigFrameHostOpenChannelToNative = 0x06b0b864;

static const uintptr_t kSlotFrameHostOpenChannelToTab    = 0x0b275088;
static const uintptr_t kOrigFrameHostOpenChannelToTab    = 0x06b0ba04;

static const uintptr_t kSlotSWHostDidInitialize          = 0x0b27a158;
static const uintptr_t kOrigSWHostDidInitialize          = 0x06b3690c;

static const uintptr_t kSlotSWHostDidStart               = 0x0b27a160;
static const uintptr_t kOrigSWHostDidStart               = 0x06b36a80;

static const uintptr_t kSlotSWHostDidStop                = 0x0b27a168;
static const uintptr_t kOrigSWHostDidStop                = 0x06b36be8;

static const uintptr_t kSlotSWHostRequestWorker          = 0x0b27a170;
static const uintptr_t kOrigSWHostRequestWorker          = 0x06b36d64;

static const uintptr_t kSlotSWHostOpenChannelToExt       = 0x0b27a180;
static const uintptr_t kOrigSWHostOpenChannelToExt       = 0x06b3714c;

static const uintptr_t kSlotSWHostOpenChannelToNative    = 0x0b27a188;
static const uintptr_t kOrigSWHostOpenChannelToNative    = 0x06b37318;

static const uintptr_t kSlotSWHostOpenChannelToTab       = 0x0b27a190;
static const uintptr_t kOrigSWHostOpenChannelToTab       = 0x06b374e0;

static const uintptr_t kSlotEventRouterAddMain           = 0x0b274a30;
static const uintptr_t kOrigEventRouterAddMain           = 0x06b01d4c;

static const uintptr_t kSlotEventRouterAddSW             = 0x0b274a38;
static const uintptr_t kOrigEventRouterAddSW             = 0x06b01f00;

static const uintptr_t kSlotEventRouterAddLazyMain       = 0x0b274a40;
static const uintptr_t kOrigEventRouterAddLazyMain       = 0x06b02070;

static const uintptr_t kSlotEventRouterAddLazySW         = 0x0b274a48;
static const uintptr_t kOrigEventRouterAddLazySW         = 0x06b02348;

static const uintptr_t kSlotEventRouterAddFiltMain       = 0x0b274a50;
static const uintptr_t kOrigEventRouterAddFiltMain       = 0x06b027c0;

static const uintptr_t kSlotEventRouterAddFiltSW         = 0x0b274a58;
static const uintptr_t kOrigEventRouterAddFiltSW         = 0x06b028a0;

static const uintptr_t kSlotEventRouterRemoveMain        = 0x0b274a60;
static const uintptr_t kOrigEventRouterRemoveMain        = 0x06b02a64;

static const uintptr_t kSlotEventRouterRemoveSW          = 0x0b274a68;
static const uintptr_t kOrigEventRouterRemoveSW          = 0x06b02be8;

static const uintptr_t kSlotEventRouterRemoveLazyMain    = 0x0b274a70;
static const uintptr_t kOrigEventRouterRemoveLazyMain    = 0x06b02d58;

static const uintptr_t kSlotEventRouterRemoveLazySW      = 0x0b274a78;
static const uintptr_t kOrigEventRouterRemoveLazySW      = 0x06b02f98;

static const uintptr_t kSlotEventRouterRemoveFiltMain    = 0x0b274a80;
static const uintptr_t kOrigEventRouterRemoveFiltMain    = 0x06b0326c;

static const uintptr_t kSlotEventRouterRemoveFiltSW      = 0x0b274a88;
static const uintptr_t kOrigEventRouterRemoveFiltSW      = 0x06b0334c;

static const uintptr_t kSlotProcessMapGetMostLikelyCtx   = 0x0b2798a8;
static const uintptr_t kOrigProcessMapGetMostLikelyCtx   = 0x032e5fdc;

static const uintptr_t kSlotCreateInstallPromptForWindow = 0x0b2d5df8;
static const uintptr_t kOrigCreateInstallPromptForWindow = 0x032e56c8;

static const uintptr_t kSlotGetNativeWindowForFunction   = 0x0b2d5e00;
static const uintptr_t kOrigGetNativeWindowForFunction   = 0x03261cf0;

// IOSGeneratedSchemas fixed-flat-map entry for "tabs" (std::string_view {data, len})
// in __DATA_CONST,__const (verified identical on ios-arm64 and ios-arm64-simulator).
static const uintptr_t kSlotTabsSchemaData               = 0x0b74f558;
static const uintptr_t kOrigTabsSchemaData               = 0x0adc6f1e;
static const uintptr_t kSlotTabsSchemaLen                = 0x0b74f560;
static const size_t    kOrigTabsSchemaLen                = 1783;

// IOSExtensionsAPIProvider vtable slots + helpers for registering the "scripting"
// API permission (kScripting = 230) and its permission feature on Build 35.
// Build 35 already compiles and registers all extensions/browser/api/scripting/*
// functions and the "scripting" schema + _api_features dependency, but upstream
// left kScripting and _permission_features:"scripting" in chrome/common/extensions/.
static const uintptr_t kSlotIOSAPIProviderAddPermFeatures = 0x0b282bf8;
static const uintptr_t kSlotIOSAPIProviderRegisterPerms   = 0x0b282c20;
static const uintptr_t kOrigIOSAPIProviderNoOp            = 0x00024014;
static const uintptr_t kFnFeatureProviderAddFeatures      = 0x00f620c4;
static const uintptr_t kFnPermissionsInfoRegisterPerms    = 0x00f879e0;
static const uintptr_t kAddrUserScriptsFeatureData        = 0x0b29e670;
static const uintptr_t kAddrUserScriptsFeatureObj         = 0x0b29e758;
static const uintptr_t kAddrUserScriptsFeatureVtable      = 0x0b747ff8;
static const uintptr_t kAddrUserScriptsNameStr            = 0x0a1473e5;
enum { kConstSimpleFeatureDataSize = 0xE8 };
static const uint64_t  kAPIPermissionIDScripting          = 230;
static const uint64_t  kAPIPermissionFlagMgmtWarning      = 0x40;

// Struct & virtual-table offsets verified against Build 35 disassembly.
static const size_t kVtblRPHGetBrowserContext      = 0x158;
static const size_t kVtblRPHGetID                  = 0x170;

static const size_t kVtblRFHGetSiteInstance        = 0x078;
static const size_t kVtblRFHGetProcess             = 0x080;
static const size_t kVtblRFHGetLastCommittedOrigin = 0x188;
static const size_t kVtblRFHIsSandboxed            = 0x318;
static const size_t kVtblRFHIsErrorDocument        = 0x3e0;
static const size_t kVtblRFHHasPolicyContainerHost = 0x440;

static const size_t kVtblSiteInstanceGetPrincipal  = 0x040;
static const size_t kVtblPrincipalIsSandboxed      = 0x010;
static const size_t kVtblPrincipalIsGuest          = 0x018;

static const uint32_t kWebSandboxFlagOrigin        = 4;
static const uint32_t kContextTypeContentScript    = 2;

#pragma mark - Chromium ABI mirror types (read-only / stack-backed views)

// libc++ std::__Cr::string (64-bit little-endian layout used by Chromium).
typedef struct {
    union {
        struct {
            const char *data;
            uint64_t size;
            uint64_t cap_flag; // bit 63 set => long string
        } l;
        struct {
            char data[23];
            uint8_t size;      // bit 7 clear => short string
        } s;
    };
} CrString;

_Static_assert(sizeof(CrString) == 24, "CrString must be 24 bytes");

typedef struct {
    int32_t child_id;
    uint32_t pad;
    CrString extension_id;
} CrProcessMapEntry;

_Static_assert(sizeof(CrProcessMapEntry) == 32, "CrProcessMapEntry must be 32 bytes");

typedef struct {
    uint64_t words[2];
} CrPendingRemote;

typedef struct {
    const char *data;
    size_t len;
} CrStrView;

static inline CrStrView CrStringView(const CrString *str) {
    CrStrView v = {NULL, 0};
    if (!str) {
        return v;
    }
    if ((str->s.size & 0x80u) != 0) {
        v.data = str->l.data;
        v.len = (size_t)str->l.size;
    } else {
        v.data = str->s.data;
        v.len = (size_t)str->s.size;
    }
    return v;
}

static inline CrString CrMakeLongStringView(const char *buf, size_t len) {
    CrString s;
    memset(&s, 0, sizeof(s));
    s.l.data = buf;
    s.l.size = (uint64_t)len;
    s.l.cap_flag = (uint64_t)(len + 1) | (1ULL << 63);
    return s;
}

static inline bool CrIsValidExtensionIDBytes(const char *data, size_t len) {
    if (!data || len != 32) {
        return false;
    }
    for (size_t i = 0; i < 32; i++) {
        if (data[i] < 'a' || data[i] > 'p') {
            return false;
        }
    }
    return true;
}

static inline bool CrExtractValidExtensionID(const CrString *str, char out_id[33]) {
    CrStrView v = CrStringView(str);
    if (!CrIsValidExtensionIDBytes(v.data, v.len)) {
        return false;
    }
    memcpy(out_id, v.data, 32);
    out_id[32] = '\0';
    return true;
}

static inline bool CrOriginExtractExtensionID(const uint8_t *origin, char out_id[33]) {
    if (!origin) {
        return false;
    }
    // url::Origin layout: scheme at +0x08, host at +0x20, opaque flag at +0x48.
    if ((origin[0x48] & 1u) != 0) {
        return false;
    }
    CrStrView scheme = CrStringView((const CrString *)(origin + 0x08));
    if (scheme.len != 16 || !scheme.data || memcmp(scheme.data, "chrome-extension", 16) != 0) {
        return false;
    }
    return CrExtractValidExtensionID((const CrString *)(origin + 0x20), out_id);
}

#pragma mark - Resolved engine function pointers

static uintptr_t gSlide = 0;

static void (*gFnOriginDtor)(void *);
static void (*gFnPendingRemoteDtor)(void *);
static const CrString *(*gFnExtensionId)(const void *);
static void *(*gFnExtensionRegistryGet)(void *);
static void (*gFnOriginCopyCtor)(void *, const void *);
static void *(*gFnRenderProcessHostFromID)(int32_t);
static uintptr_t gAddrFactoryCreate;
static void (*gFnFactoriesMapEmplace)(void *, void *, const char *, void *);
static void *(*gFnProcessManagerGet)(void *);
static void *(*gFnProcessMapGet)(void *);
static const void *(*gFnExtensionSetGetByID)(const void *, const CrString *);
static void (*gFnOperatorDeleteSized)(void *, size_t);
static void *(*gFnWeakUIWindowFromUIWindow)(void *, void *);
static void (*gFnInstallPromptDataDtor)(void *);
static bool (*gFnPMHasServiceWorker)(const void *, const void *);
static bool (*gFnPMHasServiceWorkerForExt)(const void *, const CrString *);
static void *(*gFnSWTQGet)(void *);
static bool (*gFnSWTQIsCurrentActivation)(const void *, const CrString *, const void *);

// Original vtable targets saved before patching.
typedef void (*FnRegisterSubresource)(void *, int32_t, int32_t, const uint8_t *, void *);
typedef void (*FnCreateLoaderAndStart)(void *, void *, int32_t, uint32_t, const void *, void *, const void *);
typedef void (*FnFrameRequest)(void *, void *, void *);
typedef void (*FnOpenChannelToExt)(void *, void *, int32_t, const void *, const void *, void *, void *);
typedef void (*FnOpenChannelToNative)(void *, const void *, const void *, void *, void *);
typedef void (*FnOpenChannelToTab)(void *, int32_t, int32_t, const void *, int32_t, const void *, const void *, void *, void *);
typedef void (*FnSWDidInitialize)(void *, const CrString *, const void *, int64_t, int32_t, const void *, void *);
typedef void (*FnSWDidStartStop)(void *, const CrString *, const void *, const void *, int64_t, int32_t, const void *);
typedef void (*FnSWRequestWorker)(void *, void *, void *);
typedef void (*FnER2)(void *, void *);
typedef void (*FnER3)(void *, void *, void *);
typedef void (*FnER4)(void *, void *, void *, void *);
typedef void (*FnER5)(void *, void *, void *, void *, uintptr_t);
typedef void (*FnER6)(void *, void *, void *, void *, void *, uintptr_t);
typedef uint32_t (*FnGetMostLikelyCtx)(const void *, const void *, int32_t, const void *);

static FnRegisterSubresource  gOrigRegisterSubresource;
static FnCreateLoaderAndStart gOrigCreateLoaderAndStart;
static FnFrameRequest         gOrigFrameRequest;
static FnOpenChannelToExt     gOrigFrameOpenChannelToExt;
static FnOpenChannelToNative  gOrigFrameOpenChannelToNative;
static FnOpenChannelToTab     gOrigFrameOpenChannelToTab;
static FnSWDidInitialize      gOrigSWDidInitialize;
static FnSWDidStartStop       gOrigSWDidStart;
static FnSWDidStartStop       gOrigSWDidStop;
static FnSWRequestWorker      gOrigSWRequestWorker;
static FnOpenChannelToExt     gOrigSWOpenChannelToExt;
static FnOpenChannelToNative  gOrigSWOpenChannelToNative;
static FnOpenChannelToTab     gOrigSWOpenChannelToTab;
static FnER2                  gOrigERAddMain;
static FnER3                  gOrigERAddSW;
static FnER3                  gOrigERAddLazyMain;
static FnER4                  gOrigERAddLazySW;
static FnER5                  gOrigERAddFiltMain;
static FnER6                  gOrigERAddFiltSW;
static FnER2                  gOrigERRemoveMain;
static FnER3                  gOrigERRemoveSW;
static FnER3                  gOrigERRemoveLazyMain;
static FnER4                  gOrigERRemoveLazySW;
static FnER5                  gOrigERRemoveFiltMain;
static FnER6                  gOrigERRemoveFiltSW;
static FnGetMostLikelyCtx     gOrigGetMostLikelyCtx;

#pragma mark - Virtual call helpers

static inline void *VCallPtr0(const void *obj, size_t vtbl_offset) {
    void *const *vtbl = *(void *const *const *)obj;
    void *(*fn)(const void *) = (void *(*)(const void *))vtbl[vtbl_offset / sizeof(void *)];
    return fn(obj);
}

static inline int32_t VCallI32_0(const void *obj, size_t vtbl_offset) {
    void *const *vtbl = *(void *const *const *)obj;
    int32_t (*fn)(const void *) = (int32_t (*)(const void *))vtbl[vtbl_offset / sizeof(void *)];
    return fn(obj);
}

static inline bool VCallBool0(const void *obj, size_t vtbl_offset) {
    void *const *vtbl = *(void *const *const *)obj;
    bool (*fn)(const void *) = (bool (*)(const void *))vtbl[vtbl_offset / sizeof(void *)];
    return fn(obj);
}

static inline bool VCallBoolU32(const void *obj, size_t vtbl_offset, uint32_t arg) {
    void *const *vtbl = *(void *const *const *)obj;
    bool (*fn)(const void *, uint32_t) = (bool (*)(const void *, uint32_t))vtbl[vtbl_offset / sizeof(void *)];
    return fn(obj, arg);
}

// Calls ExtensionURLLoaderFactory::Create using ARM64 indirect return (x8).
static inline void CallFactoryCreate(CrPendingRemote *out_remote,
                                     void *browser_context,
                                     bool is_web_view,
                                     int32_t child_id,
                                     void *opt_origin_buf) {
    register void *x0 __asm__("x0") = browser_context;
    register uintptr_t x1 __asm__("x1") = is_web_view ? 1 : 0;
    register uintptr_t x2 __asm__("x2") = (uint32_t)child_id;
    register void *x3 __asm__("x3") = opt_origin_buf;
    register void *x8 __asm__("x8") = out_remote;
    register uintptr_t fn __asm__("x9") = gAddrFactoryCreate;
    __asm__ volatile(
        "blr x9"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x8), "+r"(fn)
        :
        : "x4", "x5", "x6", "x7", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x30",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
          "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
          "cc", "memory");
}

#pragma mark - Browser-verified identity checks

static bool IsEnabledExtension(void *browser_context, const char ext_id[33]) {
    if (!browser_context || !CrIsValidExtensionIDBytes(ext_id, 32)) {
        return false;
    }
    void *registry = gFnExtensionRegistryGet(browser_context);
    if (!registry) {
        return false;
    }
    CrString id_view = CrMakeLongStringView(ext_id, 32);
    const void *enabled_set = (const uint8_t *)registry + 0x08;
    return gFnExtensionSetGetByID(enabled_set, &id_view) != NULL;
}

// Extracts the browser-verified non-sandboxed, non-guest, non-error extension
// ID from a RenderFrameHost. Returns false for webpages, sandboxed frames,
// error documents, guest views, or disabled extensions.
static bool VerifyExtensionFrame(void *rfh,
                                 void **out_browser_context,
                                 int32_t *out_child_id,
                                 char out_ext_id[33]) {
    if (!rfh) {
        return false;
    }
    void *rph = VCallPtr0(rfh, kVtblRFHGetProcess);
    if (!rph) {
        return false;
    }
    void *browser_context = VCallPtr0(rph, kVtblRPHGetBrowserContext);
    int32_t child_id = VCallI32_0(rph, kVtblRPHGetID);
    if (out_browser_context) {
        *out_browser_context = browser_context;
    }
    if (out_child_id) {
        *out_child_id = child_id;
    }
    if (!browser_context || child_id < 0) {
        return false;
    }
    if (VCallBool0(rfh, kVtblRFHIsErrorDocument)) {
        return false;
    }
    if (!VCallBool0(rfh, kVtblRFHHasPolicyContainerHost) ||
        VCallBoolU32(rfh, kVtblRFHIsSandboxed, kWebSandboxFlagOrigin)) {
        return false;
    }
    void *site_instance = VCallPtr0(rfh, kVtblRFHGetSiteInstance);
    if (!site_instance) {
        return false;
    }
    void *principal = VCallPtr0(site_instance, kVtblSiteInstanceGetPrincipal);
    if (!principal ||
        VCallBool0(principal, kVtblPrincipalIsSandboxed) ||
        VCallBool0(principal, kVtblPrincipalIsGuest)) {
        return false;
    }
    const uint8_t *origin = (const uint8_t *)VCallPtr0(rfh, kVtblRFHGetLastCommittedOrigin);
    if (!CrOriginExtractExtensionID(origin, out_ext_id)) {
        return false;
    }
    return IsEnabledExtension(browser_context, out_ext_id);
}

// Walks ProcessManager::all_extension_frames_ (libc++ RB-tree at +0x70) read-only
// to check whether |ext_id| owns a live, verified, non-sandboxed frame in |child_id|.
static bool ProcessManagerHasVerifiedFrameInProcess(void *browser_context,
                                                    const char ext_id[33],
                                                    int32_t child_id) {
    if (!browser_context) {
        return false;
    }
    void *pm = gFnProcessManagerGet(browser_context);
    if (!pm) {
        return false;
    }
    void *node = *(void *const *)((const uint8_t *)pm + 0x70);
    void *end_node = (void *)((uint8_t *)pm + 0x78);
    for (size_t steps = 0; node && node != end_node && steps < 4096; steps++) {
        void *rfh = *(void *const *)((const uint8_t *)node + 0x20);
        int32_t frame_pid = -1;
        char frame_ext[33];
        if (rfh &&
            VerifyExtensionFrame(rfh, NULL, &frame_pid, frame_ext) &&
            frame_pid == child_id &&
            memcmp(frame_ext, ext_id, 32) == 0) {
            return true;
        }
        // Standard libc++ __tree_next_iter: left=[0], right=[1], parent=[2].
        void *const *links = (void *const *)node;
        if (links[1]) {
            node = links[1];
            for (size_t down = 0; down < 128; down++) {
                void *left = ((void *const *)node)[0];
                if (!left) {
                    break;
                }
                node = left;
            }
        } else {
            void *parent = links[2];
            for (size_t up = 0; parent && up < 128; up++) {
                if (((void *const *)parent)[0] == node) {
                    node = parent;
                    break;
                }
                node = parent;
                parent = ((void *const *)node)[2];
                if (!parent) {
                    node = end_node;
                    break;
                }
            }
        }
    }
    return false;
}

static bool ProcessManagerHasActiveWorkerForExt(void *browser_context, const char ext_id[33]) {
    if (!browser_context) {
        return false;
    }
    void *pm = gFnProcessManagerGet(browser_context);
    if (!pm) {
        return false;
    }
    CrString id_view = CrMakeLongStringView(ext_id, 32);
    return gFnPMHasServiceWorkerForExt(pm, &id_view);
}

#pragma mark - Scoped ProcessMap override (UI thread synchronous only)

typedef enum {
    kScopeNone = 0,
    kScopeSwapStringInPlace,
    kScopeSwapPidInPlace,
    kScopeSwapVector,
} ScopeKind;

typedef struct {
    void *process_map;
    ScopeKind kind;
    int32_t child_id;
    size_t entry_index;
    CrString saved_str;
    int32_t saved_pid;
    CrProcessMapEntry *saved_entries;
    uint64_t saved_count;
    char ext_buf[33];
    CrProcessMapEntry stack_entries[16];
} ScopedProcessMap;

static inline void ScopeInit(ScopedProcessMap *s) {
    s->process_map = NULL;
    s->kind = kScopeNone;
}

static void ScopeBeginAllowExtension(ScopedProcessMap *s,
                                     void *browser_context,
                                     int32_t child_id,
                                     const char ext_id[33]) {
    ScopeInit(s);
    if (![NSThread isMainThread] || !browser_context || child_id < 0 ||
        !CrIsValidExtensionIDBytes(ext_id, 32)) {
        return;
    }
    void *pm = gFnProcessMapGet(browser_context);
    if (!pm) {
        return;
    }
    memcpy(s->ext_buf, ext_id, 33);
    s->process_map = pm;
    s->child_id = child_id;

    CrProcessMapEntry **entries_slot = (CrProcessMapEntry **)((uint8_t *)pm + 0x08);
    uint64_t *count_slot = (uint64_t *)((uint8_t *)pm + 0x10);
    CrProcessMapEntry *entries = *entries_slot;
    uint64_t count = *count_slot;

    if (count > 16) {
        return;
    }
    for (uint64_t i = 0; i < count; i++) {
        if (entries[i].child_id == child_id) {
            // Already scoped to this exact extension ID: skip mutating ProcessMap.
            CrStrView cur = CrStringView(&entries[i].extension_id);
            if (cur.data && cur.len == 32 && memcmp(cur.data, ext_id, 32) == 0) {
                return;
            }
            s->kind = kScopeSwapStringInPlace;
            s->entry_index = (size_t)i;
            s->saved_str = entries[i].extension_id;
            entries[i].extension_id = CrMakeLongStringView(s->ext_buf, 32);
            return;
        }
    }
    // Process not yet inserted into ProcessMap (e.g., cold-launch worker before
    // SiteInstanceGotProcessAndSite). Temporarily supply a sorted stack array.
    if (count < 16) {
        s->kind = kScopeSwapVector;
        s->saved_entries = entries;
        s->saved_count = count;
        uint64_t out = 0;
        bool inserted = false;
        for (uint64_t i = 0; i < count; i++) {
            if (!inserted && entries[i].child_id > child_id) {
                s->stack_entries[out].child_id = child_id;
                s->stack_entries[out].pad = 0;
                s->stack_entries[out].extension_id = CrMakeLongStringView(s->ext_buf, 32);
                out++;
                inserted = true;
            }
            s->stack_entries[out++] = entries[i];
        }
        if (!inserted) {
            s->stack_entries[out].child_id = child_id;
            s->stack_entries[out].pad = 0;
            s->stack_entries[out].extension_id = CrMakeLongStringView(s->ext_buf, 32);
            out++;
        }
        *entries_slot = s->stack_entries;
        *count_slot = out;
    }
}

static void ScopeBeginDenyProcess(ScopedProcessMap *s,
                                  void *browser_context,
                                  int32_t child_id) {
    ScopeInit(s);
    if (![NSThread isMainThread] || !browser_context || child_id < 0) {
        return;
    }
    void *pm = gFnProcessMapGet(browser_context);
    if (!pm) {
        return;
    }
    s->process_map = pm;
    s->child_id = child_id;

    CrProcessMapEntry **entries_slot = (CrProcessMapEntry **)((uint8_t *)pm + 0x08);
    uint64_t *count_slot = (uint64_t *)((uint8_t *)pm + 0x10);
    CrProcessMapEntry *entries = *entries_slot;
    uint64_t count = *count_slot;

    if (count == 0 || count > 16) {
        return;
    }
    if (count == 1 && entries[0].child_id == child_id) {
        s->kind = kScopeSwapPidInPlace;
        s->entry_index = 0;
        s->saved_pid = entries[0].child_id;
        entries[0].child_id = -999999;
        return;
    }
    bool found = false;
    uint64_t out = 0;
    for (uint64_t i = 0; i < count; i++) {
        if (entries[i].child_id == child_id) {
            found = true;
            continue;
        }
        s->stack_entries[out++] = entries[i];
    }
    if (found) {
        s->kind = kScopeSwapVector;
        s->saved_entries = entries;
        s->saved_count = count;
        *entries_slot = s->stack_entries;
        *count_slot = out;
    }
}

static void ScopeEnd(ScopedProcessMap *s) {
    if (!s || s->kind == kScopeNone || !s->process_map) {
        return;
    }
    CrProcessMapEntry **entries_slot = (CrProcessMapEntry **)((uint8_t *)s->process_map + 0x08);
    uint64_t *count_slot = (uint64_t *)((uint8_t *)s->process_map + 0x10);
    switch (s->kind) {
        case kScopeSwapStringInPlace: {
            CrProcessMapEntry *entries = *entries_slot;
            uint64_t count = *count_slot;
            // Only restore the slot that still holds our exact stack-backed view, so a
            // concurrent ProcessMap::Insert/Remove during the call is never clobbered.
            if (entries && s->entry_index < count &&
                entries[s->entry_index].child_id == s->child_id &&
                (entries[s->entry_index].extension_id.s.size & 0x80u) != 0 &&
                entries[s->entry_index].extension_id.l.data == s->ext_buf) {
                entries[s->entry_index].extension_id = s->saved_str;
            } else if (entries && count <= 64) {
                for (uint64_t i = 0; i < count; i++) {
                    if (entries[i].child_id == s->child_id &&
                        (entries[i].extension_id.s.size & 0x80u) != 0 &&
                        entries[i].extension_id.l.data == s->ext_buf) {
                        entries[i].extension_id = s->saved_str;
                        break;
                    }
                }
            }
            break;
        }
        case kScopeSwapPidInPlace: {
            CrProcessMapEntry *entries = *entries_slot;
            uint64_t count = *count_slot;
            if (!entries || count == 0 || count > 64) {
                break;
            }
            // If Chromium inserted a fresh entry for saved_pid while our sentinel was
            // hiding it, do not restore saved_pid (that would create duplicate keys and
            // break base::flat_map's sorted-unique invariant).
            bool duplicate_exists = false;
            size_t sentinel_index = SIZE_MAX;
            for (uint64_t i = 0; i < count; i++) {
                if (entries[i].child_id == s->saved_pid) {
                    duplicate_exists = true;
                } else if (entries[i].child_id == -999999 && sentinel_index == SIZE_MAX) {
                    sentinel_index = (size_t)i;
                }
            }
            if (!duplicate_exists && sentinel_index != SIZE_MAX) {
                entries[sentinel_index].child_id = s->saved_pid;
            }
            break;
        }
        case kScopeSwapVector:
            // Only restore if ProcessMap still points at our stack buffer (not reallocated).
            if (*entries_slot == s->stack_entries) {
                *entries_slot = s->saved_entries;
                *count_slot = s->saved_count;
            }
            break;
        case kScopeNone:
            break;
    }
    s->kind = kScopeNone;
}

#pragma mark - 1. Subresource & worker resource loading hooks

typedef struct {
    void *factory;
    uint8_t saved_has_value;
} ActiveLoaderFrame;

static ActiveLoaderFrame gActiveLoaderFrames[8];
static size_t gActiveLoaderDepth = 0;

static void HookRegisterSubresourceFactories(void *self,
                                             int32_t render_process_id,
                                             int32_t render_frame_id,
                                             const uint8_t *request_initiator_origin,
                                             void *factories) {
    // Emplace an ExtensionURLLoaderFactory carrying the browser-verified
    // request_initiator_origin in its initiator_origin_ slot (+0x68) BEFORE the
    // original method runs. std::map::emplace in the original then keeps ours
    // while still registering any WebUI chrome:// factory.
    if (render_process_id >= 0 && factories) {
        void *rph = gFnRenderProcessHostFromID(render_process_id);
        void *browser_context = rph ? VCallPtr0(rph, kVtblRPHGetBrowserContext) : NULL;
        if (browser_context) {
            _Alignas(8) uint8_t origin_copy[0x58];
            memset(origin_copy, 0, sizeof(origin_copy));
            if (request_initiator_origin && request_initiator_origin[0x50] == 1) {
                gFnOriginCopyCtor(origin_copy, request_initiator_origin);
                origin_copy[0x50] = 1;
            }
            CrPendingRemote pending = {{0, 0}};
            CallFactoryCreate(&pending, browser_context, false, render_process_id, origin_copy);
            if (origin_copy[0x50] == 1) {
                gFnOriginDtor(origin_copy);
            }
            gFnFactoriesMapEmplace(factories, factories, "chrome-extension", &pending);
            gFnPendingRemoteDtor(&pending);
        }
    }
    gOrigRegisterSubresource(self, render_process_id, render_frame_id,
                             request_initiator_origin, factories);
}

static void HookCreateLoaderAndStart(void *self,
                                     void *loader,
                                     int32_t request_id,
                                     uint32_t options,
                                     const void *request,
                                     void *client,
                                     const void *traffic_annotation) {
    uint8_t *factory = (uint8_t *)self;
    void *browser_context = *(void *const *)(factory + 0x58);
    bool is_web_view = factory[0x60] != 0;
    int32_t render_process_id = *(const int32_t *)(factory + 0x64);

    if (is_web_view || render_process_id < 0 || !browser_context) {
        gOrigCreateLoaderAndStart(self, loader, request_id, options, request,
                                  client, traffic_annotation);
        return;
    }

    // Read the browser-verified initiator_origin_ stored at +0x68 (has_value at +0xb8).
    // If re-entering on the same factory whose has_value was temporarily zeroed by an
    // outer frame, recover the true saved_has_value instead of denying a valid extension.
    uint8_t *opt_origin = factory + 0x68;
    uint8_t saved_has_value = opt_origin[0x50];
    bool is_reentrant = false;
    if ([NSThread isMainThread]) {
        for (size_t i = gActiveLoaderDepth; i > 0; i--) {
            if (gActiveLoaderFrames[i - 1].factory == self) {
                saved_has_value = gActiveLoaderFrames[i - 1].saved_has_value;
                is_reentrant = true;
                break;
            }
        }
    }

    ScopedProcessMap scope;
    ScopeInit(&scope);
    char origin_ext_id[33];
    if (saved_has_value == 1 &&
        CrOriginExtractExtensionID(opt_origin, origin_ext_id) &&
        IsEnabledExtension(browser_context, origin_ext_id)) {
        ScopeBeginAllowExtension(&scope, browser_context, render_process_id, origin_ext_id);
    } else {
        // Non-extension document (webpage) or opaque/sandboxed/disabled origin:
        // block the ProcessMap shortcut so private resources of ANY extension
        // in the shared renderer stay isolated and must pass web_accessible_resources.
        ScopeBeginDenyProcess(&scope, browser_context, render_process_id);
    }

    bool pushed_frame = false;
    bool hid_origin = false;
    if (!is_reentrant && saved_has_value != 0) {
        if ([NSThread isMainThread] && gActiveLoaderDepth < 8) {
            gActiveLoaderFrames[gActiveLoaderDepth++] = (ActiveLoaderFrame){self, saved_has_value};
            pushed_frame = true;
        }
        // Temporarily hide initiator_origin_ from ExtensionURLLoader so upstream_url_
        // matches unhooked Build 35 semantics for subresource loads.
        opt_origin[0x50] = 0;
        hid_origin = true;
    }

    gOrigCreateLoaderAndStart(self, loader, request_id, options, request,
                              client, traffic_annotation);

    if (hid_origin) {
        opt_origin[0x50] = saved_has_value;
    }
    if (pushed_frame && gActiveLoaderDepth > 0) {
        gActiveLoaderDepth--;
    }
    ScopeEnd(&scope);
}

#pragma mark - 2. ExtensionFrameHost hooks (API dispatch & messaging from frames)

static void *FrameHostCurrentFrame(void *frame_host) {
    void *frame = *(void *const *)((const uint8_t *)frame_host + 0x90);
    if (!frame) {
        void *const *slot = *(void *const *const *)((const uint8_t *)frame_host + 0x58);
        frame = slot ? *slot : NULL;
    }
    return frame;
}

static void ScopeForFrameHost(ScopedProcessMap *scope, void *frame_host) {
    ScopeInit(scope);
    void *rfh = FrameHostCurrentFrame(frame_host);
    void *browser_context = NULL;
    int32_t child_id = -1;
    char ext_id[33];
    if (VerifyExtensionFrame(rfh, &browser_context, &child_id, ext_id)) {
        ScopeBeginAllowExtension(scope, browser_context, child_id, ext_id);
    } else if (browser_context && child_id >= 0) {
        ScopeBeginDenyProcess(scope, browser_context, child_id);
    }
}

static void HookFrameRequest(void *self, void *params, void *callback) {
    ScopedProcessMap scope;
    ScopeForFrameHost(&scope, self);
    gOrigFrameRequest(self, params, callback);
    ScopeEnd(&scope);
}

static void HookFrameOpenChannelToExt(void *self, void *info, int32_t channel_type,
                                      const void *channel_name, const void *port_id,
                                      void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForFrameHost(&scope, self);
    gOrigFrameOpenChannelToExt(self, info, channel_type, channel_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

static void HookFrameOpenChannelToNative(void *self, const void *app_name,
                                         const void *port_id, void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForFrameHost(&scope, self);
    gOrigFrameOpenChannelToNative(self, app_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

static void HookFrameOpenChannelToTab(void *self, int32_t tab_id, int32_t frame_id,
                                      const void *opt_doc_id, int32_t channel_type,
                                      const void *channel_name, const void *port_id,
                                      void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForFrameHost(&scope, self);
    gOrigFrameOpenChannelToTab(self, tab_id, frame_id, opt_doc_id, channel_type,
                               channel_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

#pragma mark - 3. ServiceWorkerHost hooks (worker lifecycle, API dispatch & messaging)

static void ScopeForVerifiedServiceWorkerHost(ScopedProcessMap *scope, void *sw_host) {
    ScopeInit(scope);
    void *rph = *(void *const *)((const uint8_t *)sw_host + 0x20);
    if (!rph) {
        return;
    }
    void *browser_context = VCallPtr0(rph, kVtblRPHGetBrowserContext);
    int32_t child_id = VCallI32_0(rph, kVtblRPHGetID);
    if (!browser_context || child_id < 0) {
        return;
    }
    const void *worker_id = (const uint8_t *)sw_host + 0x70;
    char ext_id[33];
    void *pm = gFnProcessManagerGet(browser_context);
    if (pm &&
        CrExtractValidExtensionID((const CrString *)worker_id, ext_id) &&
        IsEnabledExtension(browser_context, ext_id) &&
        gFnPMHasServiceWorker(pm, worker_id)) {
        ScopeBeginAllowExtension(scope, browser_context, child_id, ext_id);
    } else {
        ScopeBeginDenyProcess(scope, browser_context, child_id);
    }
}

static bool VerifyWorkerActivation(void *sw_host,
                                   const CrString *ext_id_str,
                                   const void *activation_token,
                                   bool allow_tracked_worker,
                                   void **out_ctx,
                                   int32_t *out_child_id,
                                   char out_ext_id[33]) {
    void *rph = *(void *const *)((const uint8_t *)sw_host + 0x20);
    if (!rph) {
        return false;
    }
    void *browser_context = VCallPtr0(rph, kVtblRPHGetBrowserContext);
    int32_t child_id = VCallI32_0(rph, kVtblRPHGetID);
    if (out_ctx) {
        *out_ctx = browser_context;
    }
    if (out_child_id) {
        *out_child_id = child_id;
    }
    if (!browser_context || child_id < 0 || !CrExtractValidExtensionID(ext_id_str, out_ext_id)) {
        return false;
    }
    if (!IsEnabledExtension(browser_context, out_ext_id)) {
        return false;
    }
    void *swtq = gFnSWTQGet(browser_context);
    if (swtq && activation_token && gFnSWTQIsCurrentActivation(swtq, ext_id_str, activation_token)) {
        return true;
    }
    if (allow_tracked_worker) {
        const void *worker_id = (const uint8_t *)sw_host + 0x70;
        char tracked_ext[33];
        void *pm = gFnProcessManagerGet(browser_context);
        if (pm &&
            CrExtractValidExtensionID((const CrString *)worker_id, tracked_ext) &&
            memcmp(tracked_ext, out_ext_id, 32) == 0 &&
            gFnPMHasServiceWorker(pm, worker_id)) {
            return true;
        }
    }
    return false;
}

static void HookSWDidInitialize(void *self,
                                const CrString *ext_id,
                                const void *activation_token,
                                int64_t version_id,
                                int32_t worker_thread_id,
                                const void *sw_token,
                                void *event_dispatcher) {
    ScopedProcessMap scope;
    ScopeInit(&scope);
    void *ctx = NULL;
    int32_t child_id = -1;
    char verified_ext[33];
    if (VerifyWorkerActivation(self, ext_id, activation_token, false, &ctx, &child_id, verified_ext)) {
        ScopeBeginAllowExtension(&scope, ctx, child_id, verified_ext);
    } else if (ctx && child_id >= 0) {
        ScopeBeginDenyProcess(&scope, ctx, child_id);
    }
    gOrigSWDidInitialize(self, ext_id, activation_token, version_id,
                         worker_thread_id, sw_token, event_dispatcher);
    ScopeEnd(&scope);
}

static void HookSWDidStart(void *self,
                           const CrString *ext_id,
                           const void *activation_token,
                           const void *scope_url,
                           int64_t version_id,
                           int32_t worker_thread_id,
                           const void *sw_token) {
    ScopedProcessMap scope;
    ScopeInit(&scope);
    void *ctx = NULL;
    int32_t child_id = -1;
    char verified_ext[33];
    if (VerifyWorkerActivation(self, ext_id, activation_token, true, &ctx, &child_id, verified_ext)) {
        ScopeBeginAllowExtension(&scope, ctx, child_id, verified_ext);
    } else if (ctx && child_id >= 0) {
        ScopeBeginDenyProcess(&scope, ctx, child_id);
    }
    gOrigSWDidStart(self, ext_id, activation_token, scope_url, version_id,
                    worker_thread_id, sw_token);
    ScopeEnd(&scope);
}

static void HookSWDidStop(void *self,
                          const CrString *ext_id,
                          const void *activation_token,
                          const void *scope_url,
                          int64_t version_id,
                          int32_t worker_thread_id,
                          const void *sw_token) {
    ScopedProcessMap scope;
    ScopeInit(&scope);
    void *ctx = NULL;
    int32_t child_id = -1;
    char verified_ext[33];
    if (VerifyWorkerActivation(self, ext_id, activation_token, true, &ctx, &child_id, verified_ext)) {
        ScopeBeginAllowExtension(&scope, ctx, child_id, verified_ext);
    } else if (ctx && child_id >= 0) {
        ScopeBeginDenyProcess(&scope, ctx, child_id);
    }
    gOrigSWDidStop(self, ext_id, activation_token, scope_url, version_id,
                   worker_thread_id, sw_token);
    ScopeEnd(&scope);
}

static void HookSWRequestWorker(void *self, void *params, void *callback) {
    ScopedProcessMap scope;
    ScopeForVerifiedServiceWorkerHost(&scope, self);
    gOrigSWRequestWorker(self, params, callback);
    ScopeEnd(&scope);
}

static void HookSWOpenChannelToExt(void *self, void *info, int32_t channel_type,
                                   const void *channel_name, const void *port_id,
                                   void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForVerifiedServiceWorkerHost(&scope, self);
    gOrigSWOpenChannelToExt(self, info, channel_type, channel_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

static void HookSWOpenChannelToNative(void *self, const void *app_name,
                                      const void *port_id, void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForVerifiedServiceWorkerHost(&scope, self);
    gOrigSWOpenChannelToNative(self, app_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

static void HookSWOpenChannelToTab(void *self, int32_t tab_id, int32_t frame_id,
                                   const void *opt_doc_id, int32_t channel_type,
                                   const void *channel_name, const void *port_id,
                                   void *port, void *port_host) {
    ScopedProcessMap scope;
    ScopeForVerifiedServiceWorkerHost(&scope, self);
    gOrigSWOpenChannelToTab(self, tab_id, frame_id, opt_doc_id, channel_type,
                            channel_name, port_id, port, port_host);
    ScopeEnd(&scope);
}

#pragma mark - 4. EventRouter hooks (listener registration & removal)

static const CrString *ExtractOwnerExtensionID(const void *owner_ptr) {
    if (!owner_ptr) {
        return NULL;
    }
    // mojom::EventListenerOwner union: tag == 0 => extension_id at +0x08.
    uint32_t tag = *(const uint32_t *)owner_ptr;
    if (tag != 0) {
        return NULL;
    }
    return (const CrString *)((const uint8_t *)owner_ptr + 0x08);
}

static const CrString *ExtractListenerExtensionID(const void *event_listener_struct_ptr) {
    if (!event_listener_struct_ptr) {
        return NULL;
    }
    const void *listener = *(const void *const *)event_listener_struct_ptr;
    if (!listener) {
        return NULL;
    }
    const void *owner = *(const void *const *)listener;
    return ExtractOwnerExtensionID(owner);
}

static void ScopeForEventRouter(ScopedProcessMap *scope,
                                void *er_subobject,
                                const CrString *ext_id_str,
                                bool is_service_worker) {
    ScopeInit(scope);
    if (!er_subobject || !ext_id_str) {
        return;
    }
    // Secondary vtable subobject is at EventRouter + 0x48.
    const uint8_t *er = (const uint8_t *)er_subobject - 0x48;
    void *browser_context = *(void *const *)(er + 0x50);
    const int32_t *ctx_pid_ptr = *(const int32_t *const *)(er + 0x390);
    if (!browser_context || !ctx_pid_ptr) {
        return;
    }
    int32_t child_id = *ctx_pid_ptr;
    char ext_id[33];
    if (child_id < 0 ||
        !CrExtractValidExtensionID(ext_id_str, ext_id) ||
        !IsEnabledExtension(browser_context, ext_id)) {
        return;
    }
    bool verified = is_service_worker
        ? ProcessManagerHasActiveWorkerForExt(browser_context, ext_id)
        : (ProcessManagerHasVerifiedFrameInProcess(browser_context, ext_id, child_id) ||
           ProcessManagerHasActiveWorkerForExt(browser_context, ext_id));
    if (verified) {
        ScopeBeginAllowExtension(scope, browser_context, child_id, ext_id);
    }
}

static void HookERAddMain(void *self, void *listener_ptr) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, ExtractListenerExtensionID(listener_ptr), false);
    gOrigERAddMain(self, listener_ptr);
    ScopeEnd(&scope);
}

static void HookERAddSW(void *self, void *listener_ptr, void *sw_ctx_ptr) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, ExtractListenerExtensionID(listener_ptr), true);
    gOrigERAddSW(self, listener_ptr, sw_ctx_ptr);
    ScopeEnd(&scope);
}

static void HookERAddLazyMain(void *self, void *ext_id, void *event_name) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, false);
    gOrigERAddLazyMain(self, ext_id, event_name);
    ScopeEnd(&scope);
}

static void HookERAddLazySW(void *self, void *ext_id, void *scope_url, void *event_name) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, true);
    gOrigERAddLazySW(self, ext_id, scope_url, event_name);
    ScopeEnd(&scope);
}

static void HookERAddFiltMain(void *self, void *owner_struct_ptr, void *event_name,
                              void *filter, uintptr_t add_lazy) {
    ScopedProcessMap scope;
    const void *owner = owner_struct_ptr ? *(const void *const *)owner_struct_ptr : NULL;
    ScopeForEventRouter(&scope, self, ExtractOwnerExtensionID(owner), false);
    gOrigERAddFiltMain(self, owner_struct_ptr, event_name, filter, add_lazy);
    ScopeEnd(&scope);
}

static void HookERAddFiltSW(void *self, void *ext_id, void *event_name,
                            void *sw_ctx_ptr, void *filter, uintptr_t add_lazy) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, true);
    gOrigERAddFiltSW(self, ext_id, event_name, sw_ctx_ptr, filter, add_lazy);
    ScopeEnd(&scope);
}

static void HookERRemoveMain(void *self, void *listener_ptr) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, ExtractListenerExtensionID(listener_ptr), false);
    gOrigERRemoveMain(self, listener_ptr);
    ScopeEnd(&scope);
}

static void HookERRemoveSW(void *self, void *listener_ptr, void *sw_ctx_ptr) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, ExtractListenerExtensionID(listener_ptr), true);
    gOrigERRemoveSW(self, listener_ptr, sw_ctx_ptr);
    ScopeEnd(&scope);
}

static void HookERRemoveLazyMain(void *self, void *ext_id, void *event_name) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, false);
    gOrigERRemoveLazyMain(self, ext_id, event_name);
    ScopeEnd(&scope);
}

static void HookERRemoveLazySW(void *self, void *ext_id, void *scope_url, void *event_name) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, true);
    gOrigERRemoveLazySW(self, ext_id, scope_url, event_name);
    ScopeEnd(&scope);
}

static void HookERRemoveFiltMain(void *self, void *owner_struct_ptr, void *event_name,
                                 void *filter, uintptr_t remove_lazy) {
    ScopedProcessMap scope;
    const void *owner = owner_struct_ptr ? *(const void *const *)owner_struct_ptr : NULL;
    ScopeForEventRouter(&scope, self, ExtractOwnerExtensionID(owner), false);
    gOrigERRemoveFiltMain(self, owner_struct_ptr, event_name, filter, remove_lazy);
    ScopeEnd(&scope);
}

static void HookERRemoveFiltSW(void *self, void *ext_id, void *event_name,
                               void *sw_ctx_ptr, void *filter, uintptr_t remove_lazy) {
    ScopedProcessMap scope;
    ScopeForEventRouter(&scope, self, (const CrString *)ext_id, true);
    gOrigERRemoveFiltSW(self, ext_id, event_name, sw_ctx_ptr, filter, remove_lazy);
    ScopeEnd(&scope);
}

#pragma mark - 5. ProcessMap::GetMostLikelyContextType hook (event dispatch classification)

static bool GURLMatchesExtensionOrigin(const void *gurl, const char ext_id[33]) {
    if (!gurl) {
        return false;
    }
    // GURL::spec_ is a std::__Cr::string at offset +0x00.
    CrStrView spec = CrStringView((const CrString *)gurl);
    // "chrome-extension://" (19) + 32-char ext_id = 51 bytes.
    if (!spec.data || spec.len < 51) {
        return false;
    }
    if (memcmp(spec.data, "chrome-extension://", 19) != 0 ||
        memcmp(spec.data + 19, ext_id, 32) != 0) {
        return false;
    }
    return spec.len == 51 || spec.data[51] == '/';
}

static uint32_t HookGetMostLikelyContextType(const void *process_map,
                                             const void *extension,
                                             int32_t child_id,
                                             const void *gurl) {
    uint32_t result = gOrigGetMostLikelyCtx(process_map, extension, child_id, gurl);
    if (!extension || result != kContextTypeContentScript || child_id < 0) {
        return result;
    }
    void *browser_context = *(void *const *)((const uint8_t *)process_map + 0x20);
    const CrString *ext_id_str = gFnExtensionId(extension);
    char ext_id[33];
    if (!browser_context || !CrExtractValidExtensionID(ext_id_str, ext_id)) {
        return result;
    }
    bool is_privileged_context = false;
    if (!gurl) {
        // Service worker event dispatch passes url == nullptr.
        is_privileged_context = ProcessManagerHasActiveWorkerForExt(browser_context, ext_id);
    } else if (GURLMatchesExtensionOrigin(gurl, ext_id)) {
        is_privileged_context =
            ProcessManagerHasVerifiedFrameInProcess(browser_context, ext_id, child_id);
    }
    if (!is_privileged_context) {
        return result;
    }
    ScopedProcessMap scope;
    ScopeBeginAllowExtension(&scope, browser_context, child_id, ext_id);
    uint32_t updated = gOrigGetMostLikelyCtx(process_map, extension, child_id, gurl);
    ScopeEnd(&scope);
    return updated;
}

#pragma mark - Hook 6: chrome.permissions.request window & native consent prompt

typedef void *(*CreateInstallPromptForWindowFn)(void *client, void *weak_window,
                                                void *browser_context, void *prompt_data);
static CreateInstallPromptForWindowFn gOrigCreateInstallPromptForWindow;
static void *gOrigGetNativeWindowForFunction;

typedef struct {
    int32_t ref_count;
    uint32_t pad;
    void (*polymorphic_invoke)(void *bind_state, const void *payload);
    void (*destructor)(const void *bind_state);
} CrBindStateBase;

typedef struct {
    uint32_t result; // 0 = ACCEPTED, 2 = USER_CANCELED
    uint32_t pad;
    uint8_t justification[24]; // Empty libc++ std::string (all zero bytes).
} CrInstallPromptDonePayload;

_Static_assert(sizeof(CrInstallPromptDonePayload) == 32,
               "CrInstallPromptDonePayload must be 32 bytes");

typedef struct CuriumInstallPrompt CuriumInstallPrompt;

@interface CuriumPromptGate : NSObject {
@public
    CuriumInstallPrompt *prompt;
}
@end

@implementation CuriumPromptGate
@end

static char kCuriumPromptAlertSentinelKey;
static void CuriumCompleteInstallPrompt(CuriumInstallPrompt *prompt, uint32_t result);

// Guarantees pending_bind_state settles with USER_CANCELED if the alert fails to
// present or is dismissed externally (e.g. its parent popup sheet dismisses on
// backgrounding) without an action button firing.
@interface CuriumPromptAlertSentinel : NSObject
@property(nonatomic, strong) CuriumPromptGate *gate;
@end

@implementation CuriumPromptAlertSentinel
- (void)dealloc {
    CuriumPromptGate *gate = _gate;
    if (!gate) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CuriumInstallPrompt *p = gate->prompt;
        if (!p) {
            return;
        }
        gate->prompt = NULL;
        CuriumCompleteInstallPrompt(p, 2 /* USER_CANCELED */);
    });
}
@end

struct CuriumInstallPrompt {
    const void *const *vtable;
    void *pending_bind_state;
    void *gate; // CFBridgingRetain(CuriumPromptGate *)
};

static UIWindow *CuriumActiveKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIWindow *candidate = windowScene.keyWindow;
        if (!candidate) {
            for (UIWindow *w in windowScene.windows) {
                if (!w.hidden && w.alpha > 0.0) {
                    candidate = w;
                    break;
                }
            }
        }
        if (candidate && scene.activationState == UISceneActivationStateForegroundActive) {
            return candidate;
        }
        if (candidate && !fallback) {
            fallback = candidate;
        }
    }
    return fallback;
}

static UIViewController *CuriumTopmostViewController(UIWindow *window) {
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void CuriumReleaseBindState(void *bs) {
    if (!bs) {
        return;
    }
    CrBindStateBase *state = (CrBindStateBase *)bs;
    int32_t prev = __atomic_fetch_sub(&state->ref_count, 1, __ATOMIC_ACQ_REL);
    if (prev == 1 && state->destructor) {
        state->destructor(state);
    }
}

static void CuriumCompleteInstallPrompt(CuriumInstallPrompt *prompt, uint32_t result) {
    if (!prompt || !prompt->pending_bind_state) {
        return;
    }
    void *bs = prompt->pending_bind_state;
    prompt->pending_bind_state = NULL;
    CrBindStateBase *state = (CrBindStateBase *)bs;
    CrInstallPromptDonePayload payload;
    memset(&payload, 0, sizeof(payload));
    payload.result = result;
    if (state->polymorphic_invoke) {
        state->polymorphic_invoke(bs, &payload);
    }
    CuriumReleaseBindState(bs);
}

static void CuriumInstallPromptNoOp(void) {}

static void CuriumInstallPromptCleanup(CuriumInstallPrompt *self) {
    if (!self) {
        return;
    }
    if (self->gate) {
        CuriumPromptGate *gate = (CuriumPromptGate *)CFBridgingRelease(self->gate);
        self->gate = NULL;
        gate->prompt = NULL;
    }
    if (self->pending_bind_state) {
        void *bs = self->pending_bind_state;
        self->pending_bind_state = NULL;
        CuriumReleaseBindState(bs);
    }
}

static void CuriumInstallPromptDtor(CuriumInstallPrompt *self) {
    CuriumInstallPromptCleanup(self);
}

static void CuriumInstallPromptDeletingDtor(CuriumInstallPrompt *self) {
    if (!self) {
        return;
    }
    CuriumInstallPromptCleanup(self);
    free(self);
}

static NSString *CuriumExtensionDisplayName(const void *extension) {
    if (extension) {
        // extensions::Extension::name_ sits at offset +0x08 (verified against Build 35).
        CrStrView nameView = CrStringView((const CrString *)((const uint8_t *)extension + 0x08));
        if (nameView.data && nameView.len > 0 && nameView.len <= 256) {
            NSString *name = [[NSString alloc] initWithBytes:nameView.data
                                                      length:nameView.len
                                                    encoding:NSUTF8StringEncoding];
            if (name.length > 0) {
                return name;
            }
        }
    }
    return @"This extension";
}

static void CuriumCancelGateAsync(CuriumPromptGate *gate) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CuriumInstallPrompt *p = gate->prompt;
        if (!p) {
            return;
        }
        gate->prompt = NULL;
        CuriumCompleteInstallPrompt(p, 2 /* USER_CANCELED */);
    });
}

static void CuriumPresentInstallPromptAlert(UIAlertController *alert,
                                            CuriumPromptGate *gate,
                                            int remainingAttempts) {
    if (!gate->prompt) {
        return;
    }
    UIViewController *presenter = CuriumTopmostViewController(CuriumActiveKeyWindow());
    if (!presenter) {
        CuriumCancelGateAsync(gate);
        return;
    }
    // Wait out an active dismissal (e.g. closing sheet/popup) so UIKit does not
    // silently drop presentViewController: and hang chrome.permissions.request().
    UIViewController *dismissingChild = presenter.presentedViewController;
    if (dismissingChild || presenter.isBeingDismissed) {
        if (remainingAttempts <= 0) {
            CuriumCancelGateAsync(gate);
            return;
        }
        id<UIViewControllerTransitionCoordinator> coordinator =
            dismissingChild.transitionCoordinator ?: presenter.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil
                                         completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> ctx) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    CuriumPresentInstallPromptAlert(alert, gate, remainingAttempts - 1);
                });
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CuriumPresentInstallPromptAlert(alert, gate, remainingAttempts - 1);
            });
        }
        return;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void CuriumInstallPromptShowDialog(CuriumInstallPrompt *self,
                                          void *bind_state,
                                          const void *extension,
                                          const void *permission_set) {
    (void)permission_set;
    if (!self) {
        CuriumReleaseBindState(bind_state);
        return;
    }
    CuriumInstallPromptCleanup(self);
    self->pending_bind_state = bind_state;

    CuriumPromptGate *gate = [[CuriumPromptGate alloc] init];
    gate->prompt = self;
    self->gate = (void *)CFBridgingRetain(gate);

    UIViewController *presenter = CuriumTopmostViewController(CuriumActiveKeyWindow());
    if (!presenter) {
        CuriumCancelGateAsync(gate);
        return;
    }

    NSString *extName = CuriumExtensionDisplayName(extension);
    NSString *title = [NSString stringWithFormat:@"Allow “%@” to access additional site data?", extName];
    NSString *message = @"This extension is requesting optional permissions to read and change data on websites.";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    CuriumPromptAlertSentinel *sentinel = [[CuriumPromptAlertSentinel alloc] init];
    sentinel.gate = gate;
    objc_setAssociatedObject(alert, &kCuriumPromptAlertSentinelKey, sentinel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [alert addAction:[UIAlertAction actionWithTitle:@"Deny"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        CuriumInstallPrompt *p = gate->prompt;
        if (!p) {
            return;
        }
        gate->prompt = NULL;
        CuriumCompleteInstallPrompt(p, 2 /* USER_CANCELED */);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Allow"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        CuriumInstallPrompt *p = gate->prompt;
        if (!p) {
            return;
        }
        gate->prompt = NULL;
        CuriumCompleteInstallPrompt(p, 0 /* ACCEPTED */);
    }]];

    CuriumPresentInstallPromptAlert(alert, gate, 3);
}

static const void *const kCuriumInstallPromptVtable[12] = {
    (const void *)CuriumInstallPromptNoOp,        // +0x00
    (const void *)CuriumInstallPromptNoOp,        // +0x08
    (const void *)CuriumInstallPromptNoOp,        // +0x10
    (const void *)CuriumInstallPromptNoOp,        // +0x18
    (const void *)CuriumInstallPromptNoOp,        // +0x20
    (const void *)CuriumInstallPromptNoOp,        // +0x28
    (const void *)CuriumInstallPromptShowDialog,  // +0x30 ShowDialog
    (const void *)CuriumInstallPromptNoOp,        // +0x38
    (const void *)CuriumInstallPromptDtor,        // +0x40 ~InstallPrompt()
    (const void *)CuriumInstallPromptDeletingDtor,// +0x48 ~InstallPrompt() deleting
    (const void *)CuriumInstallPromptNoOp,        // +0x50
    (const void *)CuriumInstallPromptNoOp,        // +0x58
};

static void *HookCreateInstallPromptForWindow(void *client,
                                              void *weak_window,
                                              void *browser_context,
                                              void *prompt_data) {
    (void)client;
    (void)weak_window;
    (void)browser_context;
    if (prompt_data) {
        gFnInstallPromptDataDtor(prompt_data);
        gFnOperatorDeleteSized(prompt_data, 0x220);
    }
    CuriumInstallPrompt *prompt = (CuriumInstallPrompt *)calloc(1, sizeof(CuriumInstallPrompt));
    if (!prompt) {
        return NULL;
    }
    prompt->vtable = kCuriumInstallPromptVtable;
    return prompt;
}

__attribute__((visibility("hidden"), used, noinline))
void CuriumGetNativeWindowForFunctionImpl(void *client, void *ext_fn, void *out_weak_window) {
    (void)client;
    (void)ext_fn;
    UIWindow *window = CuriumActiveKeyWindow();
    gFnWeakUIWindowFromUIWindow(out_weak_window, (__bridge void *)window);
}

// base::apple::WeakUIWindow is a non-trivial C++ type returned via arm64 indirect
// result register x8; forward x8 explicitly as argument 3 (x2).
__attribute__((naked))
static void HookGetNativeWindowForFunctionThunk(void) {
    __asm__ volatile(
        "mov x2, x8\n"
        "b _CuriumGetNativeWindowForFunctionImpl\n"
    );
}

#pragma mark - Image lookup and fail-closed vtable installation

static bool FindBuild35ChromeFramework(uintptr_t *out_slide) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "chrome_framework.framework/chrome_framework")) {
            continue;
        }
        const struct mach_header_64 *hdr =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr || hdr->magic != MH_MAGIC_64) {
            continue;
        }
        const uint8_t *cursor = (const uint8_t *)(hdr + 1);
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *uc = (const struct uuid_command *)lc;
                if (memcmp(uc->uuid, kBuild35UUID, sizeof(kBuild35UUID)) == 0) {
                    *out_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
                    return true;
                }
                return false;
            }
            cursor += lc->cmdsize;
        }
        return false;
    }
    return false;
}

typedef struct {
    uintptr_t slot_offset;
    uintptr_t orig_offset;
    void *replacement;
    void **orig_out;
    const char *label;
} VtablePatch;

static bool PatchVtableSlot(uintptr_t slot_addr, void *replacement) {
    size_t page_size = (size_t)getpagesize();
    uintptr_t page_start = slot_addr & ~(uintptr_t)(page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page_start,
                                  (vm_size_t)page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), (vm_address_t)page_start,
                        (vm_size_t)page_size, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    }
    if (kr != KERN_SUCCESS) {
        return false;
    }
    *(void *volatile *)slot_addr = replacement;
    (void)vm_protect(mach_task_self(), (vm_address_t)page_start,
                     (vm_size_t)page_size, FALSE, VM_PROT_READ);
    return true;
}

static char *gPatchedTabsSchemaBuf;

static void PatchTabsSchemaTabIdNone(uintptr_t slide) {
    uintptr_t data_slot = slide + kSlotTabsSchemaData;
    uintptr_t len_slot  = slide + kSlotTabsSchemaLen;
    uintptr_t expected_data = slide + kOrigTabsSchemaData;
    uintptr_t actual_data = *(const uintptr_t *)data_slot;
    size_t actual_len = *(const size_t *)len_slot;
    if (actual_data != expected_data || actual_len != kOrigTabsSchemaLen) {
        os_log_error(CuriumExtHookLog(),
                     "tabs schema TAB_ID_NONE patch: skipped, slot mismatch (data=%#lx len=%zu)",
                     (unsigned long)actual_data, actual_len);
        CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"failed",
                               @"Schema slot mismatch");
        return;
    }
    const char *orig = (const char *)actual_data;
    if (orig[actual_len - 1] != '}') {
        os_log_error(CuriumExtHookLog(), "tabs schema TAB_ID_NONE patch: skipped, unexpected tail");
        CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"failed",
                               @"Unexpected tabs schema JSON tail");
        return;
    }
    static const char kTabIdNoneProp[] =
        ",\"properties\":{\"TAB_ID_NONE\":{\"value\":-1,\"type\":\"integer\"}}}";
    const size_t prop_len = sizeof(kTabIdNoneProp) - 1;
    const size_t new_len = (actual_len - 1) + prop_len;
    char *buf = (char *)malloc(new_len + 1);
    if (!buf) {
        CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"failed", @"Allocation failed");
        return;
    }
    memcpy(buf, orig, actual_len - 1);
    memcpy(buf + (actual_len - 1), kTabIdNoneProp, prop_len + 1);
    if (!PatchVtableSlot(data_slot, buf)) {
        free(buf);
        CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"failed",
                               @"vm_protect failed on schema data slot");
        return;
    }
    if (!PatchVtableSlot(len_slot, (void *)(uintptr_t)new_len)) {
        PatchVtableSlot(data_slot, (void *)actual_data);
        free(buf);
        CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"failed",
                               @"vm_protect failed on schema length slot");
        return;
    }
    gPatchedTabsSchemaBuf = buf;
    os_log(CuriumExtHookLog(),
           "tabs schema TAB_ID_NONE patch: installed (len %zu -> %zu)",
           actual_len, new_len);
    CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"active",
                           [NSString stringWithFormat:@"len %zu -> %zu", actual_len, new_len]);
}

typedef struct {
    uint64_t id;
    const char *name;
    uint64_t flags;
    const void *constructor;
} CrAPIPermissionInitInfo;

_Static_assert(sizeof(CrAPIPermissionInitInfo) == 32, "CrAPIPermissionInitInfo must be 32 bytes");

typedef struct {
    const void *vtable;
    const void *data;
} CrConstSimpleFeatureObj;

static void (*gFnFeatureProviderAddFeatures)(void *, const void *const *, size_t);
static void (*gFnPermissionsInfoRegisterPerms)(void *, const void *, size_t, const void *, size_t);
static uint8_t gScriptingFeatureData[kConstSimpleFeatureDataSize] __attribute__((aligned(16)));
static CrConstSimpleFeatureObj gScriptingFeatureObj;
static const char kScriptingPermissionName[] = "scripting";
static const CrAPIPermissionInitInfo kScriptingPermissionInitInfo = {
    kAPIPermissionIDScripting,
    kScriptingPermissionName,
    kAPIPermissionFlagMgmtWarning,
    NULL,
};

static void HookIOSAPIProviderAddPermissionFeatures(void *self, void *provider) {
    (void)self;
    if (!provider || !gFnFeatureProviderAddFeatures) {
        return;
    }
    const void *feature_ptr = &gScriptingFeatureObj;
    gFnFeatureProviderAddFeatures(provider, &feature_ptr, 1);
}

static void HookIOSAPIProviderRegisterPermissions(void *self, void *permissions_info) {
    (void)self;
    if (!permissions_info || !gFnPermissionsInfoRegisterPerms) {
        return;
    }
    gFnPermissionsInfoRegisterPerms(permissions_info, &kScriptingPermissionInitInfo, 1, NULL, 0);
}

static void PatchScriptingAPIPermission(uintptr_t slide) {
    uintptr_t add_feat_slot = slide + kSlotIOSAPIProviderAddPermFeatures;
    uintptr_t reg_perm_slot = slide + kSlotIOSAPIProviderRegisterPerms;
    uintptr_t expected_noop = slide + kOrigIOSAPIProviderNoOp;
    if (*(const uintptr_t *)add_feat_slot != expected_noop ||
        *(const uintptr_t *)reg_perm_slot != expected_noop) {
        os_log_error(CuriumExtHookLog(),
                     "scripting API permission patch: skipped, IOSExtensionsAPIProvider slot mismatch");
        CuriumRecordHookStatus(@"Scripting API Permission", @"failed",
                               @"IOSExtensionsAPIProvider vtable slot mismatch");
        return;
    }

    // Verify the "userScripts" ConstSimpleFeature template (channel=stable,
    // extension_types=["extension"], min_manifest_version=3 — identical to "scripting").
    const void *const *tmpl_sv = (const void *const *)(slide + kAddrUserScriptsFeatureData);
    const char *tmpl_name = (const char *)tmpl_sv[0];
    size_t tmpl_len = (size_t)(uintptr_t)tmpl_sv[1];
    const CrConstSimpleFeatureObj *tmpl_obj =
        (const CrConstSimpleFeatureObj *)(slide + kAddrUserScriptsFeatureObj);
    if ((uintptr_t)tmpl_name != slide + kAddrUserScriptsNameStr ||
        tmpl_len != 11 ||
        memcmp(tmpl_name, "userScripts", 11) != 0 ||
        (uintptr_t)tmpl_obj->vtable != slide + kAddrUserScriptsFeatureVtable ||
        (uintptr_t)tmpl_obj->data != slide + kAddrUserScriptsFeatureData) {
        os_log_error(CuriumExtHookLog(),
                     "scripting API permission patch: skipped, userScripts feature template mismatch");
        CuriumRecordHookStatus(@"Scripting API Permission", @"failed",
                               @"userScripts ConstSimpleFeature template mismatch");
        return;
    }

    memcpy(gScriptingFeatureData, (const void *)(slide + kAddrUserScriptsFeatureData),
           kConstSimpleFeatureDataSize);
    ((const char **)gScriptingFeatureData)[0] = kScriptingPermissionName;
    ((size_t *)gScriptingFeatureData)[1] = sizeof(kScriptingPermissionName) - 1;
    gScriptingFeatureObj.vtable = tmpl_obj->vtable;
    gScriptingFeatureObj.data = gScriptingFeatureData;

    gFnFeatureProviderAddFeatures =
        (void (*)(void *, const void *const *, size_t))(slide + kFnFeatureProviderAddFeatures);
    gFnPermissionsInfoRegisterPerms =
        (void (*)(void *, const void *, size_t, const void *, size_t))(slide + kFnPermissionsInfoRegisterPerms);

    if (!PatchVtableSlot(add_feat_slot, (void *)HookIOSAPIProviderAddPermissionFeatures)) {
        CuriumRecordHookStatus(@"Scripting API Permission", @"failed",
                               @"vm_protect failed on AddPermissionFeatures");
        return;
    }
    if (!PatchVtableSlot(reg_perm_slot, (void *)HookIOSAPIProviderRegisterPermissions)) {
        PatchVtableSlot(add_feat_slot, (void *)expected_noop);
        CuriumRecordHookStatus(@"Scripting API Permission", @"failed",
                               @"vm_protect failed on RegisterPermissions");
        return;
    }

    os_log(CuriumExtHookLog(),
           "scripting API permission patch: installed (kScripting=230 + MV3 stable feature)");
    CuriumRecordHookStatus(@"Scripting API Permission", @"active",
                           @"kScripting (230) + MV3 stable permission feature");
}

void CuriumInstallExtensionCoexistenceHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t slide = 0;
        if (!FindBuild35ChromeFramework(&slide)) {
            os_log(CuriumExtHookLog(),
                   "extension coexistence hooks: skipped (chrome_framework Build 35 UUID not present)");
            CuriumRecordHookStatus(@"Extension Coexistence", @"skipped",
                                   @"Build 35 chrome_framework UUID not present");
            CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"skipped",
                                   @"Build 35 chrome_framework UUID not present");
            CuriumRecordHookStatus(@"Scripting API Permission", @"skipped",
                                   @"Build 35 chrome_framework UUID not present");
            return;
        }
        gSlide = slide;

        const VtablePatch patches[] = {
            {kSlotRegisterSubresourceFactories, kOrigRegisterSubresourceFactories,
             (void *)HookRegisterSubresourceFactories, (void **)&gOrigRegisterSubresource,
             "RegisterNonNetworkSubresourceURLLoaderFactories"},
            {kSlotFactoryCreateLoaderAndStart, kOrigFactoryCreateLoaderAndStart,
             (void *)HookCreateLoaderAndStart, (void **)&gOrigCreateLoaderAndStart,
             "ExtensionURLLoaderFactory::CreateLoaderAndStart"},
            {kSlotFrameHostRequest, kOrigFrameHostRequest,
             (void *)HookFrameRequest, (void **)&gOrigFrameRequest,
             "ExtensionFrameHost::Request"},
            {kSlotFrameHostOpenChannelToExt, kOrigFrameHostOpenChannelToExt,
             (void *)HookFrameOpenChannelToExt, (void **)&gOrigFrameOpenChannelToExt,
             "ExtensionFrameHost::OpenChannelToExtension"},
            {kSlotFrameHostOpenChannelToNative, kOrigFrameHostOpenChannelToNative,
             (void *)HookFrameOpenChannelToNative, (void **)&gOrigFrameOpenChannelToNative,
             "ExtensionFrameHost::OpenChannelToNativeApp"},
            {kSlotFrameHostOpenChannelToTab, kOrigFrameHostOpenChannelToTab,
             (void *)HookFrameOpenChannelToTab, (void **)&gOrigFrameOpenChannelToTab,
             "ExtensionFrameHost::OpenChannelToTab"},
            {kSlotSWHostDidInitialize, kOrigSWHostDidInitialize,
             (void *)HookSWDidInitialize, (void **)&gOrigSWDidInitialize,
             "ServiceWorkerHost::DidInitializeServiceWorkerContext"},
            {kSlotSWHostDidStart, kOrigSWHostDidStart,
             (void *)HookSWDidStart, (void **)&gOrigSWDidStart,
             "ServiceWorkerHost::DidStartServiceWorkerContext"},
            {kSlotSWHostDidStop, kOrigSWHostDidStop,
             (void *)HookSWDidStop, (void **)&gOrigSWDidStop,
             "ServiceWorkerHost::DidStopServiceWorkerContext"},
            {kSlotSWHostRequestWorker, kOrigSWHostRequestWorker,
             (void *)HookSWRequestWorker, (void **)&gOrigSWRequestWorker,
             "ServiceWorkerHost::RequestWorker"},
            {kSlotSWHostOpenChannelToExt, kOrigSWHostOpenChannelToExt,
             (void *)HookSWOpenChannelToExt, (void **)&gOrigSWOpenChannelToExt,
             "ServiceWorkerHost::OpenChannelToExtension"},
            {kSlotSWHostOpenChannelToNative, kOrigSWHostOpenChannelToNative,
             (void *)HookSWOpenChannelToNative, (void **)&gOrigSWOpenChannelToNative,
             "ServiceWorkerHost::OpenChannelToNativeApp"},
            {kSlotSWHostOpenChannelToTab, kOrigSWHostOpenChannelToTab,
             (void *)HookSWOpenChannelToTab, (void **)&gOrigSWOpenChannelToTab,
             "ServiceWorkerHost::OpenChannelToTab"},
            {kSlotEventRouterAddMain, kOrigEventRouterAddMain,
             (void *)HookERAddMain, (void **)&gOrigERAddMain,
             "EventRouter::AddListenerForMainThread"},
            {kSlotEventRouterAddSW, kOrigEventRouterAddSW,
             (void *)HookERAddSW, (void **)&gOrigERAddSW,
             "EventRouter::AddListenerForServiceWorker"},
            {kSlotEventRouterAddLazyMain, kOrigEventRouterAddLazyMain,
             (void *)HookERAddLazyMain, (void **)&gOrigERAddLazyMain,
             "EventRouter::AddLazyListenerForMainThread"},
            {kSlotEventRouterAddLazySW, kOrigEventRouterAddLazySW,
             (void *)HookERAddLazySW, (void **)&gOrigERAddLazySW,
             "EventRouter::AddLazyListenerForServiceWorker"},
            {kSlotEventRouterAddFiltMain, kOrigEventRouterAddFiltMain,
             (void *)HookERAddFiltMain, (void **)&gOrigERAddFiltMain,
             "EventRouter::AddFilteredListenerForMainThread"},
            {kSlotEventRouterAddFiltSW, kOrigEventRouterAddFiltSW,
             (void *)HookERAddFiltSW, (void **)&gOrigERAddFiltSW,
             "EventRouter::AddFilteredListenerForServiceWorker"},
            {kSlotEventRouterRemoveMain, kOrigEventRouterRemoveMain,
             (void *)HookERRemoveMain, (void **)&gOrigERRemoveMain,
             "EventRouter::RemoveListenerForMainThread"},
            {kSlotEventRouterRemoveSW, kOrigEventRouterRemoveSW,
             (void *)HookERRemoveSW, (void **)&gOrigERRemoveSW,
             "EventRouter::RemoveListenerForServiceWorker"},
            {kSlotEventRouterRemoveLazyMain, kOrigEventRouterRemoveLazyMain,
             (void *)HookERRemoveLazyMain, (void **)&gOrigERRemoveLazyMain,
             "EventRouter::RemoveLazyListenerForMainThread"},
            {kSlotEventRouterRemoveLazySW, kOrigEventRouterRemoveLazySW,
             (void *)HookERRemoveLazySW, (void **)&gOrigERRemoveLazySW,
             "EventRouter::RemoveLazyListenerForServiceWorker"},
            {kSlotEventRouterRemoveFiltMain, kOrigEventRouterRemoveFiltMain,
             (void *)HookERRemoveFiltMain, (void **)&gOrigERRemoveFiltMain,
             "EventRouter::RemoveFilteredListenerForMainThread"},
            {kSlotEventRouterRemoveFiltSW, kOrigEventRouterRemoveFiltSW,
             (void *)HookERRemoveFiltSW, (void **)&gOrigERRemoveFiltSW,
             "EventRouter::RemoveFilteredListenerForServiceWorker"},
            {kSlotProcessMapGetMostLikelyCtx, kOrigProcessMapGetMostLikelyCtx,
             (void *)HookGetMostLikelyContextType, (void **)&gOrigGetMostLikelyCtx,
             "ProcessMap::GetMostLikelyContextType"},
            {kSlotCreateInstallPromptForWindow, kOrigCreateInstallPromptForWindow,
             (void *)HookCreateInstallPromptForWindow, (void **)&gOrigCreateInstallPromptForWindow,
             "IOSExtensionsBrowserClient::CreateInstallPromptForNativeWindow"},
            {kSlotGetNativeWindowForFunction, kOrigGetNativeWindowForFunction,
             (void *)HookGetNativeWindowForFunctionThunk, (void **)&gOrigGetNativeWindowForFunction,
             "IOSExtensionsBrowserClient::GetNativeWindowForFunction"},
        };
        const size_t patch_count = sizeof(patches) / sizeof(patches[0]);

        // Fail closed: verify every single vtable slot before writing anything.
        for (size_t i = 0; i < patch_count; i++) {
            uintptr_t slot_addr = slide + patches[i].slot_offset;
            uintptr_t expected = slide + patches[i].orig_offset;
            uintptr_t actual = *(const uintptr_t *)slot_addr;
            if (actual != expected) {
                os_log_error(CuriumExtHookLog(),
                             "extension coexistence hooks: aborted, slot mismatch for %{public}s "
                             "(actual=%#lx expected=%#lx)",
                             patches[i].label, (unsigned long)actual, (unsigned long)expected);
                CuriumRecordHookStatus(@"Extension Coexistence", @"failed",
                                       [NSString stringWithFormat:@"Slot mismatch: %s", patches[i].label]);
                CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"skipped",
                                       @"Skipped after vtable slot mismatch");
                CuriumRecordHookStatus(@"Scripting API Permission", @"skipped",
                                       @"Skipped after vtable slot mismatch");
                return;
            }
        }

        // Bind direct helpers.
        gFnOriginDtor                           = (void (*)(void *))(slide + kFnOriginDtor);
        gFnOperatorDeleteSized                  = (void (*)(void *, size_t))(slide + kFnOperatorDeleteSized);
        gFnPendingRemoteDtor                    = (void (*)(void *))(slide + kFnPendingRemoteDtor);
        gFnExtensionId                          = (const CrString *(*)(const void *))(slide + kFnExtensionId);
        gFnExtensionRegistryGet                 = (void *(*)(void *))(slide + kFnExtensionRegistryGet);
        gFnOriginCopyCtor                       = (void (*)(void *, const void *))(slide + kFnOriginCopyCtor);
        gFnRenderProcessHostFromID              = (void *(*)(int32_t))(slide + kFnRenderProcessHostFromID);
        gAddrFactoryCreate                      = slide + kFnExtensionURLLoaderFactoryCreate;
        gFnFactoriesMapEmplace                  = (void (*)(void *, void *, const char *, void *))(slide + kFnFactoriesMapEmplace);
        gFnProcessManagerGet                    = (void *(*)(void *))(slide + kFnProcessManagerGet);
        gFnProcessMapGet                        = (void *(*)(void *))(slide + kFnProcessMapGet);
        gFnExtensionSetGetByID                  = (const void *(*)(const void *, const CrString *))(slide + kFnExtensionSetGetByID);
        gFnWeakUIWindowFromUIWindow             = (void *(*)(void *, void *))(slide + kFnWeakUIWindowFromUIWindow);
        gFnInstallPromptDataDtor                = (void (*)(void *))(slide + kFnInstallPromptDataDtor);
        gFnPMHasServiceWorker                   = (bool (*)(const void *, const void *))(slide + kFnProcessManagerHasServiceWorker);
        gFnPMHasServiceWorkerForExt             = (bool (*)(const void *, const CrString *))(slide + kFnProcessManagerHasServiceWorkerForExt);
        gFnSWTQGet                              = (void *(*)(void *))(slide + kFnServiceWorkerTaskQueueGet);
        gFnSWTQIsCurrentActivation              = (bool (*)(const void *, const CrString *, const void *))(slide + kFnServiceWorkerTaskQueueIsCurrentAct);

        size_t installed = 0;
        for (size_t i = 0; i < patch_count; i++) {
            uintptr_t slot_addr = slide + patches[i].slot_offset;
            *patches[i].orig_out = *(void *const *)slot_addr;
            if (!PatchVtableSlot(slot_addr, patches[i].replacement)) {
                os_log_error(CuriumExtHookLog(),
                             "extension coexistence hooks: vm_protect failed on %{public}s; rolling back",
                             patches[i].label);
                for (size_t j = 0; j < installed; j++) {
                    PatchVtableSlot(slide + patches[j].slot_offset, *patches[j].orig_out);
                }
                CuriumRecordHookStatus(@"Extension Coexistence", @"failed",
                                       [NSString stringWithFormat:@"vm_protect failed: %s", patches[i].label]);
                CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"skipped",
                                       @"Skipped after vm_protect rollback");
                CuriumRecordHookStatus(@"Scripting API Permission", @"skipped",
                                       @"Skipped after vm_protect rollback");
                return;
            }
            installed++;
        }

        CuriumRecordHookStatus(@"Extension Coexistence", @"active",
                               [NSString stringWithFormat:@"%zu Build 35 vtable slots patched", installed]);

        PatchTabsSchemaTabIdNone(slide);
        PatchScriptingAPIPermission(slide);

        os_log(CuriumExtHookLog(),
               "extension coexistence hooks: installed (%zu vtable slots on Build 35)",
               installed);
    });
}

#else

void CuriumInstallExtensionCoexistenceHooks(void) {
    CuriumRecordHookStatus(@"Extension Coexistence", @"skipped", @"Non-arm64 architecture");
    CuriumRecordHookStatus(@"Tabs Schema TAB_ID_NONE", @"skipped", @"Non-arm64 architecture");
    CuriumRecordHookStatus(@"Scripting API Permission", @"skipped", @"Non-arm64 architecture");
}

#endif
