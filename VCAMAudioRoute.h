#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface VCAMAudioRoute : NSObject

// 安装 AVAudioSession Hook（在 %ctor 里调用）
+ (void)install;

// 卸载（在 %dtor 里调用）
+ (void)uninstall;

// 音频开关（从 preferences 读）
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;

@end