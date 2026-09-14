//
//  ObjCExceptionCatcher.m
//  Aerial4WallpaperExtension
//
//  See ObjCExceptionCatcher.h. Deliberately minimal: no logging, no
//  policy — the Swift side decides what to do with the error.
//
//  Note on ARC: -fobjc-arc-exceptions is off (Xcode default), so objects
//  allocated between the @try and the raise can leak when an exception
//  unwinds. That is the accepted price of not aborting; keep the block
//  to the single risky call so there is little to leak.
//

#import "ObjCExceptionCatcher.h"

// Sanitizer report routing. A process hosted by WallpaperAgent has no
// stderr anyone reads and no environment we can set, so when the build is
// instrumented (Scripts/audit.sh --tsan-live / --asan-live) the runtime is
// told here where to write. Reports land as
// /Users/Shared/Aerial/Logs/tsan.<pid> (or asan.<pid>). Compiled out of
// every uninstrumented build.
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
const char *__tsan_default_options(void) {
    return "log_path=/Users/Shared/Aerial/Logs/tsan:halt_on_error=0:report_signal_unsafe=0";
}
#endif
#if __has_feature(address_sanitizer)
const char *__asan_default_options(void) {
    return "log_path=/Users/Shared/Aerial/Logs/asan:halt_on_error=0";
}
#endif
#endif

NSErrorDomain const AerialObjCExceptionErrorDomain = @"com.glouel.Aerial.ObjCException";
NSErrorUserInfoKey const AerialObjCExceptionNameKey = @"AerialObjCExceptionName";
NSErrorUserInfoKey const AerialObjCExceptionReasonKey = @"AerialObjCExceptionReason";
NSErrorUserInfoKey const AerialObjCExceptionCallStackKey = @"AerialObjCExceptionCallStack";

NSError *AerialCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"(no reason)";
        NSMutableDictionary<NSErrorUserInfoKey, id> *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
        info[AerialObjCExceptionNameKey] = exception.name;
        info[AerialObjCExceptionReasonKey] = reason;
        info[AerialObjCExceptionCallStackKey] = exception.callStackSymbols ?: @[];
        return [NSError errorWithDomain:AerialObjCExceptionErrorDomain code:1 userInfo:info];
    }
}
