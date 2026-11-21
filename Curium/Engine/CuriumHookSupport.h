#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>

// Layout checks shared by the runtime hooks on the vendored engine. A hook installs
// only when every ivar and method it touches matches the expected type encoding.

// Returns the ivar only if the engine declares it with the expected type encoding.
static inline Ivar CuriumExpectIvar(Class cls, const char *name, const char *encoding) {
    if (!cls || !name || !encoding) {
        return NULL;
    }
    Ivar ivar = class_getInstanceVariable(cls, name);
    const char *types = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return (types && strcmp(types, encoding) == 0) ? ivar : NULL;
}

// Returns the method only if `cls` itself declares it (never inherited from a
// superclass such as UIResponder) with the expected type encoding.
static inline Method CuriumExpectMethod(Class cls, const char *name, const char *encoding) {
    if (!cls || !name || !encoding) {
        return NULL;
    }
    SEL sel = sel_registerName(name);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return NULL;
    }
    Class superCls = class_getSuperclass(cls);
    if (superCls && class_getInstanceMethod(superCls, sel) == method) {
        return NULL;
    }
    const char *types = method_getTypeEncoding(method);
    return (types && strcmp(types, encoding) == 0) ? method : NULL;
}

static inline void *CuriumIvarAddress(__unsafe_unretained id object, Ivar ivar) {
    return (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
}

NS_ASSUME_NONNULL_BEGIN

// Records the attachment outcome of a runtime hook for CuriumRuntimeHookStatuses().
// `status` must be @"active", @"skipped", or @"failed".
void CuriumRecordHookStatus(NSString *name, NSString *status, NSString *detail);

NS_ASSUME_NONNULL_END
