//
//  AerialWindow.h
//  Aerial
//
//  Created by Guillaume Louel on 29/08/2020.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AerialWindow : NSWindowController //<NSWindowDelegate>
- (void)awakeFromNib;
- (void)stopScreensaver;
- (NSWindow*)openPanel;
- (void)togglePause;
- (void)nextVideo;
- (void)skipAndHide;
- (float)getSpeed;
- (void)changeSpeed:(float)speed;

@end

NS_ASSUME_NONNULL_END
