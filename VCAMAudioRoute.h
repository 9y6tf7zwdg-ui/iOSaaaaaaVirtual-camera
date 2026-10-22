#import#import <Foundation/Foundation.h>
#import#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface VCAMAudioRoute : NSObject
+ (void)install;
+ (void)uninstall;
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;
@end