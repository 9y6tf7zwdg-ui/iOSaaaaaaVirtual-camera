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

// ========== 后台解码缓存 ==========
static AVAssetReader *reader = nil;
static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
static CMSampleBufferRef g_cachedFrame = nil;
static NSLock *g_frameLock = nil;
static dispatch_queue_t g_decodeQueue = nil;
static volatile BOOL g_decoderRunning = NO;

static NSTimeInterval g_lastBufferRefreshTime = 0;
static const NSTimeInterval BUFFER_REFRESH_INTERVAL = 30.0;

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

// ========== 后台解码线程 ==========
static BOOL VCAMInitReader(void) {
    @try {
        if (reader) { [reader cancelReading]; reader = nil; }
        if (videoTrackout_32BGRA) { videoTrackout_32BGRA = nil; }

        AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
        reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!videoTrack) return NO;

        videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        videoTrackout_32BGRA.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:videoTrackout_32BGRA]) return NO;
        [reader addOutput:videoTrackout_32BGRA];
        [reader startReading];
        return YES;
    } @catch (NSException *e) {
        VCAM_LOG(@"VCAMInitReader 失败: %@", e);
        return NO;
    }
}

static void VCAMDecoderLoop(void) {
    VCAM_LOG(@"解码线程启动");
    while (g_decoderRunning) {
        @autoreleasepool {
            if (reader == nil || videoTrackout_32BGRA == nil || !g_fileManager || ![g_fileManager fileExistsAtPath:g_tempFile]) {
                usleep(50000);
                continue;
            }

            CMSampleBufferRef newFrame = nil;
            @try {
                newFrame = [videoTrackout_32BGRA copyNextSampleBuffer];
            } @catch (NSException *e) {
                newFrame = nil;
            }

            if (newFrame == nil) {
                // 视频结束，重新开始
                [g_frameLock lock];
                if (g_cachedFrame) { CFRelease(g_cachedFrame); g_cachedFrame = nil; }
                [g_frameLock unlock];

                // 重新初始化 reader
                VCAMInitReader();
                usleep(50000);
                continue;
            }

            // 更新缓存
            [g_frameLock lock];
            if (g_cachedFrame) CFRelease(g_cachedFrame);
            g_cachedFrame = newFrame;
            g_lastBufferRefreshTime = [[NSDate date] timeIntervalSince1970];
            [g_frameLock unlock];

            // 约 30fps
            usleep(33000);
        }
    }
    VCAM_LOG(@"解码线程退出");
}

static void VCAMStartDecoder(void) {
    if (g_decoderRunning) return;
    g_decoderRunning = YES;
    dispatch_async(g_decodeQueue, ^{
        VCAMDecoderLoop();
    });
}

static void VCAMStopDecoder(void) {
    g_decoderRunning = NO;
}

// ========== GetFrame 类（只读缓存，不解码） ==========
@interface GetFrame : NSObject
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow *)getKeyWindow;
@end

@implementation GetFrame

+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew {
    if (originSampleBuffer != nil) {
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(originSampleBuffer);
        CMMediaType mt = CMFormatDescriptionGetMediaType(fd);
        if (mt != kCMMediaType_Video) return originSampleBuffer;
    }

    if (!g_fileManager || [g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;

    // 从缓存取一帧（极快，不加锁时间过长）
    CMSampleBufferRef cached = nil;
    [g_frameLock lock];
    if (g_cachedFrame) {
        cached = (CMSampleBufferRef)CFRetain(g_cachedFrame);
    }
    [g_frameLock unlock];

    if (!cached) return nil;

    // 如果原 buffer 为 nil（预览场景），直接返回缓存的
    if (originSampleBuffer == nil) {
        return cached;
    }

    // 拍照场景：用原 buffer 的时间戳重新构造
    CMSampleBufferRef copyBuffer = nil;
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(cached);
    if (!pixelBuffer) {
        CFRelease(cached);
        return originSampleBuffer;
    }

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
        CFDictionaryRef exif = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
        CFDictionaryRef tiff = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
        if (exif) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exif, kCMAttachmentMode_ShouldPropagate);
        if (tiff) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", tiff, kCMAttachmentMode_ShouldPropagate);
    }

    CFRelease(cached);
    return copyBuffer ? copyBuffer : originSampleBuffer;
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
}

@end

// ========== 安装替换层 ==========
static VCAMDisplayLinkTarget *g_displayTarget = nil;
static CADisplayLink *g_displayLink = nil;

static void VCAMSetupPreviewLayer(AVCaptureVideoPreviewLayer *layer) {
    if (!layer) return;
    if (![g_fileManager fileExistsAtPath:g_tempFile]) return;
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

%end

// ========== Hook 2：Session ==========
%hook AVCaptureSession

- (void)startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    VCAMStartDecoder();
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
            // ⭐ 只从缓存取，不解码
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
    g_frameLock = [[NSLock alloc] init];
    g_decodeQueue = dispatch_queue_create("com.vcam.decodeQueue", DISPATCH_QUEUE_SERIAL);

    updatePreferences();

    // 首次初始化 reader
    VCAMInitReader();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    prefsChanged,
                                    CFSTR("com.trizau.sileo.vcam.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%dtor {
    VCAMStopDecoder();
    [g_frameLock lock];
    if (g_cachedFrame) { CFRelease(g_cachedFrame); g_cachedFrame = nil; }
    [g_frameLock unlock];
    g_previewLayer = nil;
    g_maskLayer = nil;
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
}