#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#include <roothide.h>
#import <substrate.h>
#import "VCAMAudioRoute.h"

#define VCAM_LOG 1
#if VCAM_LOG
#define VCLOG(fmt, ...) NSLog(@"[VCAM] " fmt, ##__VA_ARGS__)
#else
#define VCLOG(fmt, ...) do {} while(0)
#endif

static char kVCAMPhotoDataKey;
static NSFileManager *g_fileManager = nil;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static BOOL g_cameraRunning = NO;

static AVAssetReader *reader = nil;
static AVAssetReaderVideoCompositionOutput *videoCompositionOutput = nil;
static dispatch_queue_t g_videoQueue = nil;
static NSString *g_tempFile = nil;
static NSDictionary *preferences;

static CGSize g_targetSize = {720.0, 1280.0};
static OSType g_targetFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
static BOOL g_isMirrored = NO;

// 核心：防倍速与长视频支持的时间控制器
static double g_lastFrameTime = 0;
static int64_t g_frameCounter = 0;

AVPlayer* FindPlayerInView(UIView *view, int depth) {
    if (!view || depth > 20) return nil;
    if ([view.layer isKindOfClass:[AVPlayerLayer class]]) return ((AVPlayerLayer *)view.layer).player;
    for (UIView *sub in view.subviews) {
        AVPlayer *p = FindPlayerInView(sub, depth + 1);
        if (p) return p;
    }
    return nil;
}

static void loadPreferences() {
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        preferences = (__bridge NSDictionary *)CFPreferencesCopyMultiple(keyList, CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keyList);
    }
}

static void updatePreferences() {
    loadPreferences();
    BOOL enabled = YES;
    if (preferences && [preferences objectForKey:@"enableAudio"]) {
        enabled = [[preferences objectForKey:@"enableAudio"] boolValue];
    }
    [VCAMAudioRoute setEnabled:enabled];
}

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    updatePreferences();
}

// ============ GetFrame ============
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew :(AVCaptureConnection *)connection;
@end

@implementation GetFrame

+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew :(AVCaptureConnection *)connection {
    @synchronized (self) {
        static CMSampleBufferRef sampleBuffer = nil;
        
        if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
        
        // 核心修复：控制读取速度，防止倍速和十几秒就播完
        double now = CACurrentMediaTime();
        // 如果距离上一帧不到 1/30 秒（约 0.033 秒），且不是强制重新读取（比如拍照），直接复用上一帧
        if (!forceReNew && (now - g_lastFrameTime) < (1.0 / 30.0)) {
            return sampleBuffer ? (CMSampleBufferRef)CFRetain(sampleBuffer) : nil;
        }
        
        // 如果缓存了且是用于拍照，直接返回
        if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) {
            return (CMSampleBufferRef)CFRetain(sampleBuffer);
        }

        if (originSampleBuffer != nil) {
            CVImageBufferRef originPixelBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
            if (originPixelBuffer) {
                size_t w = CVPixelBufferGetWidth(originPixelBuffer);
                size_t h = CVPixelBufferGetHeight(originPixelBuffer);
                // 强制 16 倍数对齐，防止微信硬件编码器崩溃
                g_targetSize = CGSizeMake((w + 15) & ~15, (h + 15) & ~15);
            }
            CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(originSampleBuffer);
            if (formatDesc) {
                g_targetFormat = CMFormatDescriptionGetMediaSubType(formatDesc);
            }
        }
        if (connection) {
            g_isMirrored = connection.isVideoMirrored;
        }

        // 热替换检测
        if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
            g_bufferReload = YES;
            g_frameCounter = 0;
            [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
        }

        if (g_bufferReload) {
            g_bufferReload = NO;
            g_frameCounter = 0;
            @try {
                if (reader) {
                    [reader cancelReading];
                    reader = nil;
                }
                videoCompositionOutput = nil;
                
                NSURL *fileURL = [NSURL fileURLWithPath:g_tempFile];
                AVAsset *asset = [AVAsset assetWithURL:fileURL];
                reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
                AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                if (!videoTrack) return nil;

                CGAffineTransform transform = videoTrack.preferredTransform;
                CGSize sourceSize = videoTrack.naturalSize;
                if (transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0) {
                    sourceSize = CGSizeMake(videoTrack.naturalSize.height, videoTrack.naturalSize.width);
                } else if (transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0) {
                    sourceSize = CGSizeMake(videoTrack.naturalSize.height, videoTrack.naturalSize.width);
                }

                AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
                videoComposition.renderSize = g_targetSize; 
                videoComposition.frameDuration = CMTimeMake(1, 30);

                AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
                instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

                AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
                
                CGFloat scale = MAX(g_targetSize.width / sourceSize.width, g_targetSize.height / sourceSize.height);
                CGAffineTransform scaleTransform = CGAffineTransformMakeScale(scale, scale);
                CGAffineTransform finalTransform = CGAffineTransformConcat(transform, scaleTransform);
                
                CGFloat dx = (g_targetSize.width - sourceSize.width * scale) / 2.0;
                CGFloat dy = (g_targetSize.height - sourceSize.height * scale) / 2.0;
                finalTransform = CGAffineTransformTranslate(finalTransform, dx / scale, dy / scale);

                if (g_isMirrored) {
                    CGAffineTransform mirrorTransform = CGAffineTransformMakeTranslation(g_targetSize.width, 0);
                    mirrorTransform = CGAffineTransformScale(mirrorTransform, -1.0, 1.0);
                    finalTransform = CGAffineTransformConcat(finalTransform, mirrorTransform);
                }

                [layerInstruction setTransform:finalTransform atTime:kCMTimeZero];
                instruction.layerInstructions = @[layerInstruction];
                videoComposition.instructions = @[instruction];

                videoCompositionOutput = [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[videoTrack] videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(g_targetFormat)}];
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
            // 视频播放完毕，立刻标记重载，等待下一个循环
            g_bufferReload = YES;
        } else {
            if (sampleBuffer) CFRelease(sampleBuffer);
            
            if (originSampleBuffer != nil) {
                CMSampleBufferRef copyBuffer = NULL;
                CVImageBufferRef newPixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                if (newPixelBuffer) {
                    g_frameCounter++;
                    // 使用真实的流逝时间作为时间戳，防止微信倍速或闪退
                    g_lastFrameTime = CACurrentMediaTime();
                    CMSampleTimingInfo sampleTime = {
                        .duration = CMTimeMake(1, 30),
                        .presentationTimeStamp = CMTimeMakeWithSeconds(g_lastFrameTime, 1000000000),
                        .decodeTimeStamp = kCMTimeInvalid
                    };
                    CMVideoFormatDescriptionRef videoInfo = nil;
                    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newPixelBuffer, &videoInfo);
                    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, newPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
                    CFRelease(videoInfo);
                }
                CFRelease(newBuffer);
                
                if (copyBuffer) {
                    sampleBuffer = (CMSampleBufferRef)CFRetain(copyBuffer);
                    CFRelease(copyBuffer);
                }
            } else {
                g_lastFrameTime = CACurrentMediaTime();
                sampleBuffer = (CMSampleBufferRef)CFRetain(newBuffer);
                CFRelease(newBuffer);
            }
        }
        
        return sampleBuffer ? (CMSampleBufferRef)CFRetain(sampleBuffer) : nil;
    }
}
@end

// ============ 拍照完美替换 ============
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    NSData *vcamData = objc_getAssociatedObject(self, &kVCAMPhotoDataKey);
    if (vcamData) return vcamData;
    return %orig;
}
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
    NSData *vcamData = objc_getAssociatedObject(self, &kVCAMPhotoDataKey);
    if (vcamData) return vcamData;
    return %orig;
}
%end

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
                    @try {
                        if ([g_fileManager fileExistsAtPath:g_tempFile] && photo) {
                            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :YES :nil];
                            if (newBuffer) {
                                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                                if (pixelBuffer) {
                                    CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                                    UIInterfaceOrientation orient = UIInterfaceOrientationPortrait;
                                    if (@available(iOS 13.0, *)) {
                                        orient = [UIApplication sharedApplication].windows.firstObject.windowScene.interfaceOrientation;
                                    } else {
                                        orient = [UIApplication sharedApplication].statusBarOrientation;
                                    }
                                    UIImageOrientation uiOrient = UIImageOrientationRight;
                                    if (orient == UIInterfaceOrientationPortraitUpsideDown) uiOrient = UIImageOrientationLeft;
                                    else if (orient == UIInterfaceOrientationLandscapeLeft) uiOrient = UIImageOrientationUp;
                                    else if (orient == UIInterfaceOrientationLandscapeRight) uiOrient = UIImageOrientationDown;
                                    
                                    UIImage *uiimage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:uiOrient];
                                    if (uiimage) {
                                        NSData *data = UIImageJPEGRepresentation(uiimage, 0.9);
                                        if (data) {
                                            objc_setAssociatedObject(photo, &kVCAMPhotoDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                        }
                                    }
                                }
                                CFRelease(newBuffer);
                            }
                        }
                    } @catch (NSException *e) {}
                    return orig_m(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                }), (IMP*)&orig_m);
            }
        }
    }
    %orig;
}
%end

%hook AVCaptureStillImageOutput
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :YES :nil];
    if (newBuffer) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        if (pixelBuffer) {
            CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
            UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
            if (uiimage) {
                NSData *data = UIImageJPEGRepresentation(uiimage, 0.9);
                CFRelease(newBuffer);
                return data;
            }
        }
        CFRelease(newBuffer);
    }
    return %orig;
}
%end

// ============ 预览与视频流接管 ============
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
        
        dispatch_async(g_videoQueue, ^{
            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO :nil];
            if (newBuffer) {
                if (g_previewLayer.readyForMoreMediaData) {
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                }
                CFRelease(newBuffer);
            }
        });
    }
}
%end

%hook AVCaptureSession
- (void)startRunning {
    g_cameraRunning = YES; 
    g_bufferReload = YES; 
    %orig;
}
- (void)stopRunning {
    g_cameraRunning = NO; 
    %orig;
}
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
                if (!sampleBuffer) return;
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO :connection];
                if (newBuffer) {
                    if (g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                    }
                    original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer, connection);
                    CFRelease(newBuffer);
                } else {
                    original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
                }
            } @catch (NSException *e) {
                original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }
        }), (IMP*)&original_method);
    }
    %orig;
}
%end

// ============ 时间轴 UI ============
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
            AVPlayer *player = FindPlayerInView(self.view, 0);
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
%end

// ============ 初始化 ============
%ctor {
    VCLOG(@"======== VCAM 完美版 加载 ========");
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    g_fileManager = [NSFileManager defaultManager];
    g_videoQueue = dispatch_queue_create("com.vcam.video.reader", DISPATCH_QUEUE_SERIAL);
    
    updatePreferences();
    [VCAMAudioRoute install];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

%dtor {
    VCLOG(@"======== VCAM 卸载 ========");
    g_fileManager = nil;
    [VCAMAudioRoute uninstall];
}