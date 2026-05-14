//
//  ScreenSaverPrivate.h
//  AerialScreenSaverExtension
//
//  Private ScreenSaver API declarations for macOS screensaver extensions.
//  These are private APIs used by the modern screensaver extension system.
//

#ifndef ScreenSaverPrivate_h
#define ScreenSaverPrivate_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Principal class for screensaver extensions.
/// The system instantiates this class when loading the extension.
/// Declared in Info.plist via NSExtensionPrincipalClass.
@interface ScreenSaverExtension : NSObject

- (instancetype)init;

@end

/// View controller that manages the screensaver view.
/// Declared in Info.plist via ScreenSaverViewControllerClass.
@interface ScreenSaverViewController : NSViewController

- (instancetype)init;

@end

/// View controller for the screensaver configuration sheet.
/// Declared in Info.plist via ScreenSaverConfigurationSheetViewControllerClass.
@interface ScreenSaverConfigurationViewController : NSViewController

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END

#endif /* ScreenSaverPrivate_h */
