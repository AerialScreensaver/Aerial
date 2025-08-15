//
//  AerialDesktop.h
//  Aerial Companion
//
//  Created by Guillaume Louel on 02/12/2020.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AerialDesktop : NSWindowController
- (void)awakeFromNib;
- (void)stopScreensaver;
- (void)openPanel;
- (void)togglePause;
- (void)nextVideo;
- (void)skipAndHide;
- (float)getSpeed;
- (void)changeSpeed:(float)speed;


@end

NS_ASSUME_NONNULL_END
