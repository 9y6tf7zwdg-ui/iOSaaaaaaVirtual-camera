#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <roothide.h>
#import <substrate.h>
#import "VCAMDebugLog.h"

static NSFileManager *g_fileManager = nil;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0;
static BOOL g_cameraRunning = NO;
static NSString *g_cameraPosition = @"B";
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;
static BOOL g_isIOS15OrLater = NO;

static AVAssetReader *reader = nil;
static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarFullRange = nil;

static NSTimeInterval g_lastBufferRefreshTime = 0;
static const NSTimeInterval BUFFER_REFRESH_INTERVAL = 30.0;
static dispatch_queue_t g_videoReadQueue = nil;

NSString *g_tempFile = nil;
NSString *g_isMirroredMark = nil;

static NSDictionary *preferences;

// ========== 偏好设置 ==========
static void loadPreferences() {
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        preferences = (__bridge NSDictionary *)CFPreferencesCopyMultiple(keyList, CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keyList);
    }
}

static void updatePreferences() {
    loadPreferences();
}

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    updatePreferences();
}

// ========== 看门狗定时器 ==========
static NSTimer *g_watchdogTimer = nil;

static void VCAMStartWatchdog(void) {
    if (g_watchdogTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            // 如果长时间没有更新预览，强制刷新 buffer
            if (g_cameraRunning && g_previewLayer) {
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - g_lastBufferRefreshTime > 5.0) {
                    VCAM_LOG(@"看门狗触发：长时间无更新，强制刷新");
                    g_bufferReload = YES;
                }
            }
        }];
    });
}

// ========== GetFrame 类 ==========
@interface GetFrame : NSObject
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow *)getKeyWindow;
@end

@implementation GetFrame

+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew {
    static CMSampleBufferRef sampleBuffer = nil;
    CMFormatDescriptionRef formatDescription = nil;
    CMMediaType mediaType = -1;
    CMMediaType subMediaType = -1;

    if (originSampleBuffer != nil) {
        formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
        mediaType = CMFormatDescriptionGetMediaType(formatDescription);
        subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
        if (mediaType != kCMMediaType_Video) return originSampleBuffer;
    }

    if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
    if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) return sampleBuffer;

    static NSTimeInterval renewTime = 0;
    if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - renewTime > 3) {
            renewTime = nowTime;
            g_bufferReload = YES;
        }
    }

    if (g_bufferReload) {
        g_bufferReload = NO;
        @try {
            AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!videoTrack) return nil;

            videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
            videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
            [reader addOutput:videoTrackout_32BGRA];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarVideoRange];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarFullRange];
            [reader startReading];
        } @catch (NSException *except) {
            VCAM_LOG(@"初始化读取视频出错: %@", except);
        }
    }

    // 在后台线程安全地读取
    __block CMSampleBufferRef buf32 = nil;
    __block CMSampleBufferRef bufVR = nil;
    __block CMSampleBufferRef bufFR = nil;

    dispatch_sync(g_videoReadQueue, ^{
        buf32 = [videoTrackout_32BGRA copyNextSampleBuffer];
        bufVR = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        bufFR = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];
    });

    CMSampleBufferRef newSample = nil;
    switch (subMediaType) {
        case kCVPixelFormatType_32BGRA:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, buf32, &newSample);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, bufVR, &newSample);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, bufFR, &newSample);
            break;
        default:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, buf32, &newSample);
            break;
    }
    if (buf32) CFRelease(buf32);
    if (bufVR) CFRelease(bufVR);
    if (bufFR) CFRelease(bufFR);

    if (newSample == nil) {
        g_bufferReload = YES;
    } else {
        if (sampleBuffer) CFRelease(sampleBuffer);

        if (originSampleBuffer != nil) {
            CMSampleBufferRef copyBuffer = nil;
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newSample);
            CMSampleTimingInfo sampleTime = {
                .duration = CMSampleBufferGetDuration(originSampleBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
            };
            CMVideoFormatDescriptionRef videoInfo = nil;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
            if (videoInfo) CFRelease(videoInfo);

            if (copyBuffer) {
                CFDictionaryRef exifAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                CFDictionaryRef TIFFAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
                if (exifAttachments) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exifAttachments, kCMAttachmentMode_ShouldPropagate);
                if (exifAttachments) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", TIFFAttachments, kCMAttachmentMode_ShouldPropagate);
                sampleBuffer = copyBuffer;
            }
            CFRelease(newSample);
        } else {
            sampleBuffer = newSample;
        }
    }

    if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
    return nil;
}

+ (UIWindow *)getKeyWindow {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    return keyWindow;
}

@end

// ========== DisplayLink 目标类 ==========
@interface VCAMDisplayLinkTarget : NSObject
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *layer;
@end

@implementation VCAMDisplayLinkTarget

- (void)step:(CADisplayLink *)sender {
    AVCaptureVideoPreviewLayer *layer = self.layer;
    if (!layer) return;

    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        if (g_maskLayer) g_maskLayer.opacity = 1;
        if (g_previewLayer) {
            g_previewLayer.opacity = 1;
            [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
        }
    } else {
        if (g_maskLayer) g_maskLayer.opacity = 0;
        if (g_previewLayer) g_previewLayer.opacity = 0;
    }

    if (g_cameraRunning && g_previewLayer) {
        g_previewLayer.frame = layer.bounds;
        g_previewLayer.transform = CATransform3DIdentity;

        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            static CMSampleBufferRef copyBuffer = nil;
            if (nowTime - refreshTime > 1000 / 33 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
                if (newBuffer) {
                    [g_previewLayer flush];
                    if (copyBuffer) CFRelease(copyBuffer);
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer) [g_previewLayer enqueueSampleBuffer:copyBuffer];
                }
            }
        }
    }

    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - g_lastBufferRefreshTime > BUFFER_REFRESH_INTERVAL) {
        g_lastBufferRefreshTime = currentTime;
        g_bufferReload = YES;
    }
}

@end

// ========== 安装替换层 ==========
static VCAMDisplayLinkTarget *g_displayTarget = nil;
static CADisplayLink *g_displayLink = nil;

static void VCAMSetupPreviewLayer(AVCaptureVideoPreviewLayer *layer) {
    if (!layer) return;
    if ([[layer sublayers] containsObject:g_previewLayer]) return;

    VCAM_LOG(@"VCAMSetupPreviewLayer 触发 sublayers=%lu", (unsigned long)layer.sublayers.count);

    g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
    g_maskLayer = [CALayer new];
    g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
    [layer addSublayer:g_maskLayer];
    [layer addSublayer:g_previewLayer];

    dispatch_async(dispatch_get_main_queue(), ^{
        g_previewLayer.frame = layer.bounds;
        g_maskLayer.frame = layer.bounds;
    });

    if (g_displayLink == nil) {
        g_displayTarget = [VCAMDisplayLinkTarget new];
        g_displayTarget.layer = layer;
        g_displayLink = [CADisplayLink displayLinkWithTarget:g_displayTarget selector:@selector(step:)];
        [g_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
}

// ========== Hook 1：预览层 ==========
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    %orig;
    VCAMSetupPreviewLayer(self);
}

- (void)didMoveToSuperlayer {
    %orig;
    VCAM_LOG(@"didMoveToSuperlayer: superlayer=%@", NSStringFromClass([self.superlayer class]));
    VCAMSetupPreviewLayer(self);
}

%end

// ========== Hook 2：Session ==========
%hook AVCaptureSession

- (void)startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_lastBufferRefreshTime = [[NSDate date] timeIntervalSince1970];
    g_refreshPreviewByVideoDataOutputTime = g_lastBufferRefreshTime * 1000;
    VCAMStartWatchdog();
    %orig;
}

- (void)stopRunning {
    g_cameraRunning = NO;
    %orig;
}

- (void)addInput:(AVCaptureDeviceInput *)input {
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
    }
    %orig;
}

- (void)addOutput:(AVCaptureOutput *)output {
    %orig;
}

%end

// ========== Hook 3：拍照（旧接口） ==========
%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                    completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler {
    g_canReleaseBuffer = NO;
    void (^newHandler)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:imageDataSampleBuffer :YES];
        if (newBuffer) imageDataSampleBuffer = newBuffer;
        handler(imageDataSampleBuffer, error);
        g_canReleaseBuffer = YES;
    };
    %orig(connection, [newHandler copy]);
}

+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}

%end

// ========== Hook 4：拍照（iOS 15+ 接口） ==========
%hook AVCapturePhotoOutput

+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer
                                   previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer {
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings == nil || delegate == nil) return %orig;

    if (g_isIOS15OrLater) {
        if (@available(iOS 15.0, *)) {
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                static NSMutableArray *hooked;
                if (hooked == nil) hooked = [NSMutableArray new];
                NSString *className = NSStringFromClass([delegate class]);
                if ([hooked containsObject:className] == NO) {
                    [hooked addObject:className];
                    __block void (*original_method)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *) = nil;
                    MSHookMessageEx([delegate class],
                                    @selector(captureOutput:didFinishProcessingPhoto:error:),
                                    imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *output, AVCapturePhoto *photo, NSError *error) {
                        if (![g_fileManager fileExistsAtPath:g_tempFile]) {
                            return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), output, photo, error);
                        }
                        g_canReleaseBuffer = NO;
                        static CMSampleBufferRef copyBuffer = nil;

                        CMSampleBufferRef tempBuffer = nil;
                        CVPixelBufferRef tempPixelBuffer = photo.pixelBuffer;
                        CMSampleTimingInfo sampleTime = {0};
                        CMVideoFormatDescriptionRef videoInfo = nil;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, &videoInfo);
                        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &tempBuffer);
                        if (videoInfo) CFRelease(videoInfo);

                        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:tempBuffer :YES];
                        if (tempBuffer) CFRelease(tempBuffer);

                        if (newBuffer) {
                            if (copyBuffer) CFRelease(copyBuffer);
                            CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                            __block CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(copyBuffer);
                            CIImage *ciimage = [CIImage imageWithCVImageBuffer:imageBuffer];
                            UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                            __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);

                            __block NSData *(*fileDataRepresentation)(id, SEL);
                            MSHookMessageEx([photo class], @selector(fileDataRepresentation),
                                            imp_implementationWithBlock(^NSData *(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentation(self, @selector(fileDataRepresentation));
                            }), (IMP *)&fileDataRepresentation);

                            __block CVImageBufferRef (*pixelBuffer)(id, SEL);
                            MSHookMessageEx([photo class], @selector(pixelBuffer),
                                            imp_implementationWithBlock(^CVImageBufferRef(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return imageBuffer;
                                return pixelBuffer(self, @selector(pixelBuffer));
                            }), (IMP *)&pixelBuffer);

                            __block CGImageRef (*CGImageRepresentation)(id, SEL);
                            MSHookMessageEx([photo class], @selector(CGImageRepresentation),
                                            imp_implementationWithBlock(^CGImageRef(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return (CGImageRef)NULL;
                                return CGImageRepresentation(self, @selector(CGImageRepresentation));
                            }), (IMP *)&CGImageRepresentation);
                        }

                        g_canReleaseBuffer = YES;
                        return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), output, photo, error);
                    }), (IMP *)&original_method);
                }
            }
        }
    }
    %orig;
}

%end

// ========== Hook 5：视频数据流 ==========
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) return %orig;

    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    if ([hooked containsObject:className] == NO) {
        [hooked addObject:className];
        __block void (*original_method)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
        MSHookMessageEx([sampleBufferDelegate class],
                        @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                        imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
            g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];
            g_photoOrientation = [connection videoOrientation];
            if (newBuffer && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                [g_previewLayer flush];
                [g_previewLayer enqueueSampleBuffer:newBuffer];
            }
            return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer ?: sampleBuffer, connection);
        }), (IMP *)&original_method);
    }
    %orig;
}

%end

// ========== 初始化 ==========
%ctor {
    VCAM_LOG_STARTUP();

    g_isMirroredMark = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/vcam_is_mirrored_mark")];
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];

    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}]) {
        g_isIOS15OrLater = YES;
    }
    g_fileManager = [NSFileManager defaultManager];
    g_videoReadQueue = dispatch_queue_create("com.vcam.videoRead", DISPATCH_QUEUE_SERIAL);

    updatePreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    prefsChanged,
                                    CFSTR("com.trizau.sileo.vcam.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%dtor {
    g_previewLayer = nil;
    g_maskLayer = nil;
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    g_watchdogTimer = nil;
}