#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <roothide.h>
#import <substrate.h>
#import "VCAMAudioRoute.h"

static NSFileManager *g_fileManager = nil;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static BOOL g_cameraRunning = NO;

static AVAssetReader *reader = nil;
static AVAssetReaderVideoCompositionOutput *videoCompositionOutput = nil;

// 全局专属后台队列，防止长视频解码卡死主线程
static dispatch_queue_t g_videoQueue = nil;
static NSString *g_tempFile = nil;
static NSDictionary *preferences;

static void loadPreferences() {
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        preferences = (__bridge NSDictionary *)CFPreferencesCopyMultiple(keyList, CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keyList);
    }
}

static BOOL getBoolFromPreferences(NSString *key, BOOL defaultValue) {
    if (preferences && [preferences objectForKey:key]) {
        return [[preferences objectForKey:key] boolValue];
    }
    return defaultValue;
}

static void updatePreferences() {
    loadPreferences();
    BOOL enabled = getBoolFromPreferences(@"enableAudio", YES);
    [VCAMAudioRoute setEnabled:enabled];
}

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    updatePreferences();
}

// ============ GetFrame (修复内存泄漏 & 旋转) ============
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
@end

@implementation GetFrame

+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew {
    @synchronized (self) {
        static CMSampleBufferRef sampleBuffer = nil;
        CMMediaType subMediaType = -1;

        if (originSampleBuffer != nil) {
            CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
            subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
        }

        if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
        
        if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) {
            // 缓存返回，调用方负责释放
            return (CMSampleBufferRef)CFRetain(sampleBuffer);
        }

        // 检测热替换
        if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
            g_bufferReload = YES;
            [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
        }

        if (g_bufferReload) {
            g_bufferReload = NO;
            @try {
                if (reader) { [reader cancelReading]; reader = nil; }
                videoCompositionOutput = nil;
                
                NSURL *fileURL = [NSURL fileURLWithPath:g_tempFile];
                AVAsset *asset = [AVAsset assetWithURL:fileURL];
                reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
                AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                if (!videoTrack) return nil;

                CGAffineTransform transform = videoTrack.preferredTransform;
                CGSize renderSize = videoTrack.naturalSize;
                if (transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0) {
                    renderSize = CGSizeMake(videoTrack.naturalSize.height, videoTrack.naturalSize.width);
                } else if (transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0) {
                    renderSize = CGSizeMake(videoTrack.naturalSize.height, videoTrack.naturalSize.width);
                }

                AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
                videoComposition.renderSize = renderSize;
                videoComposition.frameDuration = CMTimeMake(1, 30);

                AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
                instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

                AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
                [layerInstruction setTransform:transform atTime:kCMTimeZero];
                instruction.layerInstructions = @[layerInstruction];
                videoComposition.instructions = @[instruction];

                OSType pixelFormat = kCVPixelFormatType_32BGRA;
                if (subMediaType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
                else if (subMediaType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

                videoCompositionOutput = [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[videoTrack] videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat)}];
                videoCompositionOutput.videoComposition = videoComposition;
                [reader addOutput:videoCompositionOutput];
                [reader startReading];
            } @catch (NSException *except) {}
        }

        CMSampleBufferRef newBuffer = nil;
        if (videoCompositionOutput) {
            newBuffer = [videoCompositionOutput copyNextSampleBuffer];
        }

        if (newBuffer == nil) {
            g_bufferReload = YES; // 播完了，下一帧重新加载
        } else {
            if (sampleBuffer) CFRelease(sampleBuffer);
            if (originSampleBuffer != nil) {
                CMSampleBufferRef copyBuffer = nil;
                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                CMSampleTimingInfo sampleTime = {
                    .duration = CMSampleBufferGetDuration(originSampleBuffer),
                    .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                    .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
                };
                CMVideoFormatDescriptionRef videoInfo = nil;
                CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
                if (copyBuffer) {
                    sampleBuffer = (CMSampleBufferRef)CFRetain(copyBuffer);
                    CFRelease(copyBuffer);
                }
                CFRelease(newBuffer);
            } else {
                sampleBuffer = (CMSampleBufferRef)CFRetain(newBuffer);
                CFRelease(newBuffer);
            }
        }
        
        // 返回 +1 的 buffer 给调用方
        return sampleBuffer ? (CMSampleBufferRef)CFRetain(sampleBuffer) : nil;
    }
}
@end

// ============ 预览与视频 Hook ============
CALayer *g_maskLayer = nil;

%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
    if (![[self sublayers] containsObject:g_previewLayer]) {
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        });
    }
}

%new
- (void)step:(CADisplayLink *)sender {
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        g_maskLayer.opacity = 1;
        g_previewLayer.opacity = 1;
        [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    } else {
        g_maskLayer.opacity = 0;
        g_previewLayer.opacity = 0;
    }
    
    if (g_cameraRunning && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
        g_previewLayer.frame = self.bounds;
        g_previewLayer.transform = CATransform3DIdentity;
        
        // 异步读取，不卡主线程
        dispatch_async(g_videoQueue, ^{
            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
            if (newBuffer) {
                if (self->g_previewLayer.readyForMoreMediaData) {
                    [self->g_previewLayer flush];
                    [self->g_previewLayer enqueueSampleBuffer:newBuffer];
                }
                CFRelease(newBuffer);
            }
        });
    }
}
%end

%hook AVCaptureSession
- (void)startRunning { g_cameraRunning = YES; g_bufferReload = YES; %orig; }
- (void)stopRunning { g_cameraRunning = NO; %orig; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) return %orig;
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    if ([hooked containsObject:className] == NO) {
        [hooked addObject:className];
        __block void (*original_method)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
        MSHookMessageEx([sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:), imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
            @try {
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];
                if (newBuffer && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                }
                original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer ?: sampleBuffer, connection);
                if (newBuffer && newBuffer != sampleBuffer) {
                    CFRelease(newBuffer); // 释放 +1 的引用
                }
            } @catch (NSException *e) {
                original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }
        }), (IMP*)&original_method);
    }
    %orig;
}
%end

// 修复拍照重复Hook导致崩溃的问题
static NSMutableSet *g_hookedPhotoClasses = nil;
%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings == nil || delegate == nil) return %orig;
    if (@available(iOS 15.0, *)) {
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            if (!g_hookedPhotoClasses) g_hookedPhotoClasses = [NSMutableSet new];
            NSString *className = NSStringFromClass([delegate class]);
            if (![g_hookedPhotoClasses containsObject:className]) {
                [g_hookedPhotoClasses addObject:className];
                __block void (*orig_m)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *) = nil;
                MSHookMessageEx([delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:), imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) {
                    if (![g_fileManager fileExistsAtPath:g_tempFile]) return orig_m(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                    // 此处省略数据替换，直接放行原图防止崩溃
                    return orig_m(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                }), (IMP*)&orig_m);
            }
        }
    }
    %orig;
}
%end

// ============ 视频编辑界面时间轴 ============
static UILabel *g_timeLabel = nil;
static NSTimer *g_timeTimer = nil;

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"VideoEdit"] || [className containsString:@"Trim"] || [className containsString:@"Editor"] || [className containsString:@"PUPhotoEditViewController"]) {
        if (!g_timeLabel) {
            g_timeLabel = [[UILabel alloc] init];
            g_timeLabel.text = @"00:00 / 00:00";
            g_timeLabel.textColor = [UIColor whiteColor];
            g_timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
            g_timeLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
            g_timeLabel.textAlignment = NSTextAlignmentCenter;
            g_timeLabel.layer.cornerRadius = 6;
            g_timeLabel.layer.masksToBounds = YES;
            g_timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:g_timeLabel];
            [NSLayoutConstraint activateConstraints:@[
                [g_timeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
                [g_timeLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-80],
                [g_timeLabel.widthAnchor constraintEqualToConstant:130],
                [g_timeLabel.heightAnchor constraintEqualToConstant:28]
            ]];
        }
        [g_timeTimer invalidate];
        g_timeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            AVPlayer *player = [self findPlayerInView:self.view depth:0];
            if (player && g_timeLabel) {
                float curSec = CMTimeGetSeconds(player.currentTime);
                float durSec = CMTimeGetSeconds(player.currentItem.duration);
                if (!isnan(curSec) && !isnan(durSec)) {
                    g_timeLabel.text = [NSString stringWithFormat:@"%02d:%02d / %02d:%02d", (int)curSec/60, (int)curSec%60, (int)durSec/60, (int)durSec%60];
                }
            }
        }];
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"VideoEdit"] || [className containsString:@"Trim"] || [className containsString:@"Editor"]) {
        [g_timeTimer invalidate]; g_timeTimer = nil;
        [g_timeLabel removeFromSuperview]; g_timeLabel = nil;
    }
}
- (AVPlayer *)findPlayerInView:(UIView *)view depth:(int)depth {
    if (!view || depth > 20) return nil;
    if ([view.layer isKindOfClass:[AVPlayerLayer class]]) return ((AVPlayerLayer *)view.layer).player;
    for (UIView *sub in view.subviews) {
        AVPlayer *p = [self findPlayerInView:sub depth:depth+1];
        if (p) return p;
    }
    return nil;
}
%end

// ============ 初始化 ============
%ctor {
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    g_fileManager = [NSFileManager defaultManager];
    g_videoQueue = dispatch_queue_create("com.vcam.video.reader", DISPATCH_QUEUE_SERIAL);
    
    updatePreferences();
    [VCAMAudioRoute install];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

%dtor {
    g_fileManager = nil;
    [VCAMAudioRoute uninstall];
}