//
//  ObjCExceptionCatcher.h
//  Aerial4WallpaperExtension
//
//  The one piece of Objective-C in the project, and it exists for a
//  language reason: Swift cannot catch an NSException. Anything raised
//  inside a private-API call — an unrecognized selector after an OS
//  update, a KVC key that vanished, a Core Animation argument check —
//  unwinds to the top of the thread and aborts the process (for the
//  wallpaper extension: a black desktop). This runs `block` under
//  @try and hands the exception back as an NSError so Swift can log it
//  and fall back. ObjCException.swift is the Swift face of it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns nil when it completed normally, otherwise an
/// NSError (domain `AerialObjCExceptionErrorDomain`) describing the
/// NSException it raised.
NSError *_Nullable AerialCatchObjCException(void (NS_NOESCAPE ^block)(void));

extern NSErrorDomain const AerialObjCExceptionErrorDomain;
extern NSErrorUserInfoKey const AerialObjCExceptionNameKey;       // NSString
extern NSErrorUserInfoKey const AerialObjCExceptionReasonKey;     // NSString
extern NSErrorUserInfoKey const AerialObjCExceptionCallStackKey;  // NSArray<NSString *>

NS_ASSUME_NONNULL_END
