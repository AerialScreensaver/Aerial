//
//  AerialWindow.m
//  Aerial
//
//  Created by Guillaume Louel on 29/08/2020.
//

#import "Aerial_Companion-Swift.h"
#import "AerialWindow.h"
#include <dlfcn.h>
#import <Cocoa/Cocoa.h>
#import "AerialView.h"

@interface AerialWindow ()
@property (strong) IBOutlet NSView *mainView;
@property (strong) IBOutlet NSView *childView;

@property AerialView *ssv;
//@property AerialView *stsv;

@property void *handle;
@end

@implementation AerialWindow
- (void)awakeFromNib {
    // Load Aerial's bundle
    [self loadBundle];
    
    [super awakeFromNib];
    NSLog(@"awoken");
  
    //[self.window setDelegate:self];
    [self.window.contentView setAutoresizesSubviews:YES];
}

- (void) loadBundle {
    if (_handle == nil) {
        NSString *path = [NSString stringWithFormat: @"%@/Contents/MacOS/Aerial", [Constant aerialPath]];
        NSLog(@"WOOO %@", path);
        const char* st = [path UTF8String];
        _handle = dlopen(st, RTLD_LAZY);

        NSLog(@"Bundle loaded");
    } else {
        NSLog(@"Bundle previously loaded");
    }
}

- (NSWindow*) openPanel {
    [self loadBundle];

    NSLog(@"av : %@", NSClassFromString(@"AerialView"));
    // We pass true for isPreview when we want AerialView to not setup itself.
    // This is a bit of a weird workaround that requires at least Aerial 2.2.6 ;)
    // Aerial checks for isPreview and if its running under Companion to prevent the
    // window setup, which saves it from instantiating a view (since for a screensaver
    // you just alloc init the window and that loads the whole thing, which we *don't* want here)
    AerialView *_stsv = [[NSClassFromString(@"AerialView") alloc]
            initWithFrame:
            CGRectMake(0, 0,
                       self.window.frame.size.width,
                       self.window.frame.size.height)
            isPreview:true];
    
    return [_stsv configureSheet];
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
    
    // Create a new AerialView of the window's inner size
    _ssv = [[NSClassFromString(@"AerialView") alloc]
            initWithFrame:
            CGRectMake(0, 0,
                       self.window.frame.size.width,
                       self.window.frame.size.height)
            isPreview:false];
  
    [self.window setContentView: _ssv];
    
    //[self.window setLevel:NSFullScreenModeWindowLevel];
    /*
    [self.window  setLevel:kCGDesktopWindowLevel - 1];
    [self.window setCollectionBehavior:
                (NSWindowCollectionBehaviorCanJoinAllSpaces |
                 NSWindowCollectionBehaviorStationary |
                 NSWindowCollectionBehaviorIgnoresCycle)];*/
    
    
    //  [self setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle)];
}

- (void)stopScreensaver {
    [_ssv stopAnimation];
    _ssv = nil;
    
    int i = dlclose(_handle);
    NSLog(@"Window closed %d",i);
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


@end
