#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>

// Layout checks shared by the runtime hooks on the vendored engine. A hook installs
// only when every ivar and method it touches matches the expected type encoding.

// Returns the ivar only if the engine declares it with the expected type encoding.
static inline Ivar CuriumExpectIvar(Class cls, const char *name, const char *encoding) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar && strcmp(ivar_getTypeEncoding(ivar), encoding) == 0 ? ivar : NULL;
}

// Returns the method only if the engine declares it with the expected type encoding.
static inline Method CuriumExpectMethod(Class cls, const char *name, const char *encoding) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0 ? method : NULL;
}

static inline void *CuriumIvarAddress(__unsafe_unretained id object, Ivar ivar) {
    return (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
}
