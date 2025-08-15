#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.glouel.AerialUpdater";

/// The "hero color" asset catalog color resource.
static NSString * const ACColorNameHeroColor AC_SWIFT_PRIVATE = @"hero color";

/// The "orange color" asset catalog color resource.
static NSString * const ACColorNameOrangeColor AC_SWIFT_PRIVATE = @"orange color";

/// The "Status48" asset catalog image resource.
static NSString * const ACImageNameStatus48 AC_SWIFT_PRIVATE = @"Status48";

/// The "Status48Attention" asset catalog image resource.
static NSString * const ACImageNameStatus48Attention AC_SWIFT_PRIVATE = @"Status48Attention";

/// The "StatusGreen48" asset catalog image resource.
static NSString * const ACImageNameStatusGreen48 AC_SWIFT_PRIVATE = @"StatusGreen48";

/// The "StatusTransp48" asset catalog image resource.
static NSString * const ACImageNameStatusTransp48 AC_SWIFT_PRIVATE = @"StatusTransp48";

/// The "Updater512" asset catalog image resource.
static NSString * const ACImageNameUpdater512 AC_SWIFT_PRIVATE = @"Updater512";

#undef AC_SWIFT_PRIVATE
