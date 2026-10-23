#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Photos/Photos.h>
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
static char kVCAMPhotoImageKey;
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

static double g_lastFrameTime = 0;
static int64_t g_frameCounter = 0;
static CMSampleBufferRef g_cachedSampleBuffer = nil;

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
+ (CMSampleBufferRef _Nullable)getCachedFrame;
@end

@implementation GetFrame

+ (CMSampleBufferRef _Nullable)getCachedFrame {
    @synchronized (self) {
        if (g_cachedSampleBuffer && CMSampleBufferIsValid(g_cachedSampleBuffer)) {
            return (CMSampleBufferRef)CFRetain(g_cachedSampleBuffer);
        }
        return [self getCurrentFrame:nil :YES :nil];
    }
}

+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew :(AVCaptureConnection *)connection {
    @synchronized (self) {
        if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
        
        double now = CACurrentMediaTime();
        if (!forceReNew && (now - g_lastFrameTime) < (1.0 / 30.0)) {
            return g_cachedSampleBuffer ? (CMSampleBufferRef)CFRetain(g_cachedSampleBuffer) : nil;
        }
        
        if (g_cachedSampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(g_cachedSampleBuffer) && forceReNew != YES) {
            return (CMSampleBufferRef)CFRetain(g_cachedSampleBuffer);
        }

        if (originSampleBuffer != nil) {
            CVImageBufferRef originPixelBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
            if (originPixelBuffer) {
                size_t w = CVPixelBufferGetWidth(originPixelBuffer);
                size_t h = CVPixelBufferGetHeight(originPixelBuffer);
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

        if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
            g_bufferReload = YES;
            g_frameCounter = 0;
            [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
        }

        if (g_bufferReload) {
            g_bufferReload = NO;
            g_frameCounter = 0;
            @try {
                if (reader) { [reader cancelReading]; reader = nil; }
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
            g_bufferReload = YES;
            if (videoCompositionOutput) {
                g_bufferReload = NO;
                @try {
                    if (reader) { [reader cancelReading]; reader = nil; }
                    NSURL *fileURL = [NSURL fileURLWithPath:g_tempFile];
                    AVAsset *asset = [AVAsset assetWithURL:fileURL];
                    reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
                    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                    if (videoTrack) {
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
                        newBuffer = [videoCompositionOutput copyNextSampleBuffer];
                    }
                } @catch (NSException *e) {}
            }
        }

        if (newBuffer != nil) {
            if (g_cachedSampleBuffer) CFRelease(g_cachedSampleBuffer);
            if (originSampleBuffer != nil) {
                CMSampleBufferRef copyBuffer = NULL;
                CVImageBufferRef newPixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                if (newPixelBuffer) {
                    g_frameCounter++;
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
                    g_cachedSampleBuffer = (CMSampleBufferRef)CFRetain(copyBuffer);
                    CFRelease(copyBuffer);
                }
            } else {
                g_lastFrameTime = CACurrentMediaTime();
                g_cachedSampleBuffer = (CMSampleBufferRef)CFRetain(newBuffer);
                CFRelease(newBuffer);
            }
        }
        return g_cachedSampleBuffer ? (CMSampleBufferRef)CFRetain(g_cachedSampleBuffer) : nil;
    }
}
@end

// ============ 原有的 AVCapturePhoto 拦截 ============
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    NSData *vcamData = objc_getAssociatedObject(self, &kVCAMPhotoDataKey);
    if (!vcamData && [g_fileManager fileExistsAtPath:g_tempFile]) {
        CMSampleBufferRef buf = [GetFrame getCachedFrame];
        if (buf) {
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buf);
            if (pixelBuffer) {
                CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                UIImage *uiimage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:UIImageOrientationRight];
                if (uiimage) vcamData = UIImageJPEGRepresentation(uiimage, 0.9);
            }
            CFRelease(buf);
        }
    }
    if (vcamData) return vcamData;
    return %orig;
}
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
    NSData *vcamData = objc_getAssociatedObject(self, &kVCAMPhotoDataKey);
    if (!vcamData && [g_fileManager fileExistsAtPath:g_tempFile]) {
        CMSampleBufferRef buf = [GetFrame getCachedFrame];
        if (buf) {
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buf);
            if (pixelBuffer) {
                CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                UIImage *uiimage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:UIImageOrientationRight];
                if (uiimage) vcamData = UIImageJPEGRepresentation(uiimage, 0.9);
            }
            CFRelease(buf);
        }
    }
    if (vcamData) return vcamData;
    return %orig;
}
- (CGImageRef)CGImageRepresentation {
    UIImage *vcamImage = objc_getAssociatedObject(self, &kVCAMPhotoImageKey);
    if (!vcamImage && [g_fileManager fileExistsAtPath:g_tempFile]) {
        CMSampleBufferRef buf = [GetFrame getCachedFrame];
        if (buf) {
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buf);
            if (pixelBuffer) {
                CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                vcamImage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:UIImageOrientationRight];
            }
            CFRelease(buf);
        }
    }
    if (vcamImage && vcamImage.CGImage) return CGImageRetain(vcamImage.CGImage);
    return %orig;
}
%end

// ============ 微信等第三方 App 拦截 ============
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
                            CMSampleBufferRef newBuffer = [GetFrame getCachedFrame];
                            if (newBuffer) {
                                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                                if (pixelBuffer) {
                                    CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                                    UIImage *uiimage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:UIImageOrientationRight];
                                    if (uiimage) {
                                        NSData *data = UIImageJPEGRepresentation(uiimage, 0.9);
                                        if (data) {
                                            objc_setAssociatedObject(photo, &kVCAMPhotoDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                            objc_setAssociatedObject(photo, &kVCAMPhotoImageKey, uiimage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    CMSampleBufferRef newBuffer = [GetFrame getCachedFrame];
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

// ============ 降维打击：拦截相册保存接口 ============
%hook PHAssetCreationRequest
- (void)addResourceWithType:(PHAssetResourceType)type data:(NSData *)data options:(PHAssetResourceCreationOptions *)options {
    if ([g_fileManager fileExistsAtPath:g_tempFile] && (type == PHAssetResourceTypePhoto || type == PHAssetResourceTypeFullSizePhoto)) {
        CMSampleBufferRef buf = [GetFrame getCachedFrame];
        if (buf) {
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buf);
            if (pixelBuffer) {
                CIImage *ciImage = [CIImage imageWithCVImageBuffer:pixelBuffer];
                UIImage *uiimage = [UIImage imageWithCIImage:ciImage scale:1.0 orientation:UIImageOrientationRight];
                if (uiimage) {
                    NSData *vcamData = UIImageJPEGRepresentation(uiimage, 0.9);
                    if (vcamData) {
                        VCLOG(@"成功拦截相册保存，替换为虚拟数据");
                        CFRelease(buf);
                        return %orig(type, vcamData, options);
                    }
                }
            }
            CFRelease(buf);
        }
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
    if (g_cachedSampleBuffer) {
        CFRelease(g_cachedSampleBuffer);
        g_cachedSampleBuffer = nil;
    }
    [VCAMAudioRoute uninstall];
}