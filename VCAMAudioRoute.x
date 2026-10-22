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

static BOOL g_audio_enabled = YES;
static NSString *g_audio_tempFile = nil;
static NSMutableArray *hookedAudioDelegates = nil;

static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioTrackOutput = nil;

@implementation VCAMAudioRoute

+ (void)install {
    g_audio_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
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
    g_audio_enabled = enabled;
    ALOG(@"音频开关: %d", enabled);
}

+ (BOOL)isEnabled {
    return g_audio_enabled;
}

+ (void)reloadAudioReader {
    @synchronized (self) {
        if (g_audioReader) {
            [g_audioReader cancelReading];
            g_audioReader = nil;
        }
        g_audioTrackOutput = nil;
        
        if (!g_audio_tempFile || ![[NSFileManager defaultManager] fileExistsAtPath:g_audio_tempFile]) return;
        
        NSURL *url = [NSURL fileURLWithPath:g_audio_tempFile];
        AVAsset *asset = [AVAsset assetWithURL:url];
        AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!audioTrack) return;
        
        g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        
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
}

+ (CMSampleBufferRef)copyNextAudioBuffer {
    @synchronized (self) {
        if (!g_audioReader || g_audioReader.status == AVAssetReaderStatusCompleted || g_audioReader.status == AVAssetReaderStatusFailed) {
            [self reloadAudioReader];
        }
        if (g_audioReader && g_audioTrackOutput) {
            return [g_audioTrackOutput copyNextSampleBuffer];
        }
    }
    return NULL;
}
@end

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
                
                if (!g_audio_enabled || ![[NSFileManager defaultManager] fileExistsAtPath:g_audio_tempFile]) {
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
                }
                
                @try {
                    CMSampleBufferRef vcamAudioBuffer = [VCAMAudioRoute copyNextAudioBuffer];
                    if (vcamAudioBuffer) {
                        CMSampleTimingInfo timingInfo;
                        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
                        
                        CMSampleBufferRef finalBuffer = NULL;
                        CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, vcamAudioBuffer, 1, &timingInfo, &finalBuffer);
                        
                        original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, finalBuffer ?: sampleBuffer, connection);
                        
                        if (finalBuffer) CFRelease(finalBuffer);
                        CFRelease(vcamAudioBuffer);
                        return;
                    }
                } @catch (NSException *e) {}
                
                original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method);
        }
    }
    %orig;
}
%end