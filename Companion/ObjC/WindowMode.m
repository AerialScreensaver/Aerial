//
//  WindowMode.m
//  Aerial
//
//  Created by Guillaume Louel on 29/08/2020.
//

#import "WindowMode.h"
#include <dlfcn.h>
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>

@implementation WindowMode

- (id)init {
    void *handle = dlopen("/Users/glouel/Aerial.saver/Contents/MacOS/Aerial", RTLD_LAZY);
    
    return self;
}

- (void) openInWindow {
    //void *handle = dlopen("/Users/glouel/Aerial.saver/Contents/MacOS/Aerial", RTLD_LAZY);
    //NSLog(@"handle %@", handle);

    ScreenSaverView *av = [[NSClassFromString(@"AerialView") alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720) isPreview:true];
    NSLog(@"av %@", av);

    NSUInteger windowStyleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable; //
       
    id window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                                            styleMask:windowStyleMask backing:NSBackingStoreBuffered defer:NO];
    [window cascadeTopLeftFromPoint:NSMakePoint(20,20)];
    [window setTitle: @"Aerial Companion"];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    
    //[[window contentView] addSubview:av];

    //dlclose(handle);
    //return av
}



@end
