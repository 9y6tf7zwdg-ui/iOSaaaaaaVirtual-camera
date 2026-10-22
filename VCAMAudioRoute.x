#import "VCAMAudioRoute.h"
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#include <roothide.h>

#define VCAM_AUDIO_LOG 1
#if VCAM_AUDIO_LOG
#define ALOG(fmt, ...) NSLog(@"[VCAM-Audio] " fmt, ##__VA_ARGS__)
#else
#define ALOG(fmt, ...) do {} while(0)
#endif

static BOOL g_enabled = YES;
static NSString *g_tempFile = nil;
static NSMutableArray *hookedAudioDelegates = nil;

// 音频读取器
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioTrackOutput = nil;

@implementation VCAMAudioRoute

+ (void)install {
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    hookedAudioDelegates = [NSMutableArray new];
    ALOG(@"音频路由模块已安装");
}

+ (void)uninstall {
    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
    }
    g_audioTrackOutput = nil;
    hookedAudioDelegates = nil;
    ALOG(@"音频路由模块已卸载");
}

+ (void)setEnabled:(BOOL)enabled {
    g_enabled = enabled;
    ALOG(@"音频开关: %d", enabled);
}

+ (BOOL)isEnabled {
    return g_enabled;
}

// 循环读取视频音轨
+ (void)reloadAudioReader {
    if (g_audioReader) {
        [g_audioReader cancelReading];
        g_audioReader = nil;
    }
    g_audioTrackOutput = nil;
    
    if (!g_tempFile || ![[NSFileManager defaultManager] fileExistsAtPath:g_tempFile]) return;
    
    NSURL *url = [NSURL fileURLWithPath:g_tempFile];
    AVAsset *asset = [AVAsset assetWithURL:url];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!audioTrack) return;
    
    NSError *error = nil;
    g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        ALOG(@"AVAssetReader 初始化失败: %@", error);
        return;
    }
    
    // 强制转换为微信/系统最喜欢的 PCM 16-bit 单声道 44100Hz 格式
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @1
    };
    
    g_audioTrackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:settings];
    if ([g_audioReader canAddOutput:g_audioTrackOutput]) {
        [g_audioReader addOutput:g_audioTrackOutput];
        [g_audioReader startReading];
    }
}

+ (CMSampleBufferRef)copyNextAudioBuffer {
    @synchronized (self) {
        if (!g_audioReader || g_audioReader.status == AVAssetReaderStatusCompleted || g_audioReader.status == AVAssetReaderStatusFailed) {
            [self reloadAudioReader]; // 读完了自动循环
        }
        if (g_audioReader && g_audioTrackOutput) {
            return [g_audioTrackOutput copyNextSampleBuffer];
        }
    }
    return NULL;
}

@end


// ============ AVCaptureAudioDataOutput Hook ============
%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate && sampleBufferCallbackQueue) {
        NSString *className = NSStringFromClass([sampleBufferDelegate class]);
        
        if (![hookedAudioDelegates containsObject:className]) {
            [hookedAudioDelegates addObject:className];
            
            __block void (*original_method)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
            
            MSHookMessageEx([sampleBufferDelegate class],
                            @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                
                // 没开启或文件不存在，走原麦克风逻辑
                if (!g_enabled || ![[NSFileManager defaultManager] fileExistsAtPath:g_tempFile]) {
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
                }
                
                @try {
                    CMSampleBufferRef vcamAudioBuffer = [VCAMAudioRoute copyNextAudioBuffer];
                    if (vcamAudioBuffer) {
                        // 借用系统麦克风的时间戳，确保微信认为音频是连续的
                        CMSampleTimingInfo timingInfo;
                        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
                        
                        CMSampleBufferRef finalBuffer = NULL;
                        CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, vcamAudioBuffer, 1, &timingInfo, &finalBuffer);
                        
                        // 将视频里的声音喂给微信
                        original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, finalBuffer ?: sampleBuffer, connection);
                        
                        if (finalBuffer) CFRelease(finalBuffer);
                        CFRelease(vcamAudioBuffer);
                        return;
                    }
                } @catch (NSException *e) {
                    ALOG(@"音频 Hook 异常: %@", e);
                }
                
                // 如果出错，立刻回退真实麦克风，保证通话不中断
                original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method);
        }
    }
    %orig;
}
%end