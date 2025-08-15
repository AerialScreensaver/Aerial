//
//  AerialDesktop.m
//  Aerial Companion
//
//  Created by Guillaume Louel on 02/12/2020.
//

#import "Aerial_Companion-Swift.h"
#import "AerialDesktop.h"
#include <dlfcn.h>
#import <Cocoa/Cocoa.h>
//#import <ScreenSaver/ScreenSaver.h>
#import "AerialView.h"

@interface PluginLoader : NSObject
+ (instancetype)sharedInstance;
+ (void)addView;
+ (void)removeView;
@end

@implementation PluginLoader

static NSInteger _viewCount = 0;
static void* _handle;
+ (instancetype)sharedInstance {
    static PluginLoader *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[PluginLoader alloc] init];
    });
    return sharedInstance;
}

+ (void)addView {
    //
    if (_viewCount == 0) {
        NSString *path = [NSString stringWithFormat: @"%@/Contents/MacOS/Aerial", [Constant aerialPath]];
        NSLog(@"PL Loading %@", path);

        const char* st = [path UTF8String];
        _handle = dlopen(st, RTLD_LAZY);
    }
    
    _viewCount++;
    NSLog(@"PL Count %ld", (long)_viewCount);
}

+ (void)removeView {
    _viewCount--;
    
    if (_viewCount == 0) {
        int i = dlclose(_handle);
        NSLog(@"PL Closed %d", i);
    }
}

@end


@interface AerialDesktop ()
@property AerialView *ssv;
//@property NSWindowController *pwc;
@end

@implementation AerialDesktop
- (void)awakeFromNib {
    
    [super awakeFromNib];
  
    //[self.window setDelegate:self];
    [self.window.contentView setAutoresizesSubviews:YES];
}

- (void)openPanel {
    //_pwc = [[NSClassFromString(@"PanelWindowController") alloc] init];
    //[_pwc showWindow:self];
}

- (void)togglePause {
    [_ssv togglePause];
}

- (void)nextVideo {
    [_ssv nextVideo];
}

- (void)skipAndHide {
    [_ssv skipAndHide];
}

- (float)getSpeed {
    return [_ssv getGlobalSpeed];
}

- (void)changeSpeed:(float) fSpeed {
    [_ssv setGlobalSpeed:fSpeed];
}


- (void)windowWillLoad {
    [super windowWillLoad];
}

- (void)windowDidLoad {
    [super windowDidLoad];
    
    // Ensure our Aerial plugin is loaded and increment the count
    [PluginLoader addView];
    
    // Create a new AerialView of the window's inner size
    _ssv = [[NSClassFromString(@"AerialView") alloc]
            initWithFrame:
            CGRectMake(0, 0,
                       self.window.screen.frame.size.width,
                       self.window.screen.frame.size.height)
            isPreview:false];
  
    //NSLog(@"width %f",self.window.screen.frame.size.width);
    [self.window setContentView: _ssv];
    
    [self.window setFrame: [self.window.screen frame] display: YES animate: NO];

    /*if (@available(macOS 13, *)) {
        [self.window setLevel:kCGDesktopWindowLevel];
    } else {*/
    
    //[self.window setLevel:kCGDesktopWindowLevel - 1];
    //}
    
    [self.window setCollectionBehavior:
                (NSWindowCollectionBehaviorCanJoinAllSpaces |
                 NSWindowCollectionBehaviorStationary |
                 NSWindowCollectionBehaviorIgnoresCycle)];
}

- (void)stopScreensaver {
    [_ssv stopAnimation];
    _ssv = nil;
    [PluginLoader removeView];
}

@end
