#import "VCAMAudioRoute.h"
#import <substrate.h>

#define VCAM_AUDIO_LOG 1
#if VCAM_AUDIO_LOG
#define ALOG(fmt, ...) NSLog(@"[VCAM-Audio] " fmt, ##__VA_ARGS__)
#else
#define ALOG(fmt, ...) do {} while(0)
#endif

static BOOL g_enabled = YES;

@implementation VCAMAudioRoute

+ (void)install {
    ALOG(@"音频路由模块已安装");
    // Hook 由下方的 %hook 自动生效，此方法仅用于日志
}

+ (void)uninstall {
    ALOG(@"音频路由模块已卸载");
}

+ (void)setEnabled:(BOOL)enabled {
    g_enabled = enabled;
    ALOG(@"音频开关: %d", enabled);
}

+ (BOOL)isEnabled {
    return g_enabled;
}

@end

// ============ AVAudioSession Hook ============
%hook AVAudioSession

- (BOOL)setCategory:(AVAudioSessionCategory)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    ALOG(@"setCategory: %@ options: %lu", category, (unsigned long)options);

    if (g_enabled && [category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        AVAudioSessionCategoryOptions newOptions = options | AVAudioSessionCategoryOptionMixWithOthers;
        ALOG(@"覆盖：PlayAndRecord -> Playback + MixWithOthers");
        return %orig(AVAudioSessionCategoryPlayback, newOptions, outError);
    }
    return %orig;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category error:(NSError **)outError {
    ALOG(@"setCategory(简单版): %@", category);

    if (g_enabled && [category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        ALOG(@"覆盖：PlayAndRecord -> Playback");
        return %orig(AVAudioSessionCategoryPlayback, outError);
    }
    return %orig;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    ALOG(@"setCategory:mode:options: %@ mode: %@ options: %lu", category, mode, (unsigned long)options);

    if (g_enabled && [category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        AVAudioSessionCategoryOptions newOptions = options | AVAudioSessionCategoryOptionMixWithOthers;
        ALOG(@"覆盖：PlayAndRecord -> Playback + MixWithOthers");
        return %orig(AVAudioSessionCategoryPlayback, mode, newOptions, outError);
    }
    return %orig;
}

- (BOOL)setMode:(AVAudioSessionMode)mode error:(NSError **)outError {
    ALOG(@"setMode: %@", mode);
    return %orig;
}

- (BOOL)overrideOutputAudioPort:(AVAudioSessionPortOverride)portOverride error:(NSError **)outError {
    ALOG(@"overrideOutputAudioPort: %ld", (long)portOverride);
    return %orig;
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    ALOG(@"setActive: %d", active);
    return %orig;
}

%end