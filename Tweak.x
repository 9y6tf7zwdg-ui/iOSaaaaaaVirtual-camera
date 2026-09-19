#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#include <roothide.h>
#import <substrate.h>

static NSFileManager *g_fileManager = nil;
static UIPasteboard *g_pasteboard = nil;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0;
static BOOL g_cameraRunning = NO;
static NSString *g_cameraPosition = @"B";
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;

static AVAssetReader *reader = nil;
static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarFullRange = nil;

// 用户旋转角度
static CGFloat g_userRotation = 0;

// 音频注入
static AVAssetReader *g_audioReader = nil;
static AVAssetReaderTrackOutput *g_audioReplacementOutput = nil;
static AudioStreamBasicDescription g_micAudioFormat = {0};
static BOOL g_audioInjectionReady = NO;
static BOOL g_audioEnabled = YES;

#define AUDIO_RING_BUFFER_SIZE (48000 * 4)
static int16_t *g_audioRingBuffer = NULL;
static volatile int g_audioRingBufferReadPos = 0;
static volatile int g_audioRingBufferWritePos = 0;
static volatile int g_audioRingBufferAvailable = 0;

static NSTimeInterval g_lastBufferRefreshTime = 0;
static const NSTimeInterval BUFFER_REFRESH_INTERVAL = 30.0;
static BOOL g_isIOS15OrLater = NO;

// 帧率节流
static NSTimeInterval g_lastRotationTime = 0;
static const NSTimeInterval ROTATION_THROTTLE = 1.0 / 20.0;

NSString *g_isMirroredMark = nil;
NSString *g_tempFile = nil;

static NSDictionary *preferences;

static void loadPreferences() {
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        preferences = (__bridge NSDictionary *)CFPreferencesCopyMultiple(keyList, CFSTR("com.trizau.sileo.vcam"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keyList);
    }
}
static BOOL getBoolFromPreferences(NSString *key, BOOL defaultValue) {
    if (preferences && [preferences objectForKey:key]) return [[preferences objectForKey:key] boolValue];
    return defaultValue;
}
static void updatePreferences() {
    loadPreferences();
    g_audioEnabled = getBoolFromPreferences(@"enableAudio", YES);
}
static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    updatePreferences();
}

// ===== 角度持久化 =====
static void loadUserRotation() {
    g_userRotation = [[NSUserDefaults standardUserDefaults] floatForKey:@"vcam_user_rotation"];
}
static void saveUserRotation(CGFloat rad) {
    g_userRotation = rad;
    [[NSUserDefaults standardUserDefaults] setFloat:rad forKey:@"vcam_user_rotation"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static NSString *rotationLabel(CGFloat rad) {
    if (fabs(rad) < 0.01) return @"0°";
    if (fabs(rad - M_PI_2) < 0.01) return @"90°";
    if (fabs(rad - M_PI) < 0.01) return @"180°";
    if (fabs(rad + M_PI_2) < 0.01) return @"270°";
    return @"0°";
}

// ===== vImage 只做旋转（不缩放） =====
static CVPixelBufferRef rotatePixelBufferOnly(CVPixelBufferRef src, CGFloat angleRadians) {
    if (!src) return NULL;
    if (fabs(angleRadians) < 0.001) return CVPixelBufferRetain(src);

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);

    BOOL swap = (fabs(angleRadians - M_PI_2) < 0.01 || fabs(angleRadians + M_PI_2) < 0.01);
    size_t newW = swap ? h : w;
    size_t newH = swap ? w : h;

    CVPixelBufferRef dst = NULL;
    NSDictionary *opts = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, newW, newH,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)opts, &dst);
    if (ret != kCVReturnSuccess || !dst) return CVPixelBufferRetain(src);

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    vImage_Buffer srcBuf = {
        .data = CVPixelBufferGetBaseAddress(src),
        .height = h,
        .width = w,
        .rowBytes = CVPixelBufferGetBytesPerRow(src)
    };
    vImage_Buffer dstBuf = {
        .data = CVPixelBufferGetBaseAddress(dst),
        .height = newH,
        .width = newW,
        .rowBytes = CVPixelBufferGetBytesPerRow(dst)
    };

    Pixel_8888 bg = {0, 0, 0, 0};
    vImage_Error err = kvImageNoError;

    if (fabs(angleRadians - M_PI_2) < 0.01) {
        err = vImageRotate90_ARGB8888(&srcBuf, &dstBuf, kRotate90DegreesClockwise, bg, kvImageNoFlags);
    } else if (fabs(angleRadians + M_PI_2) < 0.01) {
        err = vImageRotate90_ARGB8888(&srcBuf, &dstBuf, kRotate270DegreesClockwise, bg, kvImageNoFlags);
    } else if (fabs(fabs(angleRadians) - M_PI) < 0.01) {
        err = vImageRotate90_ARGB8888(&srcBuf, &dstBuf, kRotate180DegreesClockwise, bg, kvImageNoFlags);
    }

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);

    if (err != kvImageNoError) {
        CVPixelBufferRelease(dst);
        return CVPixelBufferRetain(src);
    }
    return dst;
}

// ===== 悬浮按钮（只在 AVCaptureSession 运行时显示） =====
static UIWindow *g_buttonWindow = nil;
static UIButton *g_rotateBtn = nil;

@interface VCAMButtonHandler : NSObject
+ (instancetype)shared;
- (void)cycle:(UIButton *)btn;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

@implementation VCAMButtonHandler
+ (instancetype)shared {
    static VCAMButtonHandler *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [VCAMButtonHandler new]; });
    return h;
}
- (void)cycle:(UIButton *)btn {
    if (fabs(g_userRotation) < 0.01) saveUserRotation(M_PI_2);
    else if (fabs(g_userRotation - M_PI_2) < 0.01) saveUserRotation(M_PI);
    else if (fabs(g_userRotation - M_PI) < 0.01) saveUserRotation(-M_PI_2);
    else saveUserRotation(0);
    [btn setTitle:rotationLabel(g_userRotation) forState:UIControlStateNormal];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void showRotateButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_rotateBtn) return;

        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (scene && !g_buttonWindow) {
            g_buttonWindow = [[UIWindow alloc] initWithWindowScene:scene];
            g_buttonWindow.windowLevel = UIWindowLevelAlert + 2000;
            g_buttonWindow.backgroundColor = [UIColor clearColor];
            g_buttonWindow.hidden = NO;
            g_buttonWindow.userInteractionEnabled = YES;
            UIViewController *rootVC = [[UIViewController alloc] init];
            rootVC.view.backgroundColor = [UIColor clearColor];
            g_buttonWindow.rootViewController = rootVC;
        }
        if (!g_buttonWindow) return;

        CGFloat w = 54;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(g_buttonWindow.bounds.size.width - w - 15, 100, w, w);
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        btn.layer.cornerRadius = w / 2.0;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [btn setTitle:rotationLabel(g_userRotation) forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn addTarget:[VCAMButtonHandler shared] action:@selector(cycle:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[VCAMButtonHandler shared] action:@selector(pan:)];
        [btn addGestureRecognizer:pan];
        [g_buttonWindow addSubview:btn];
        g_rotateBtn = btn;
    });
}

static void hideRotateButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_rotateBtn) {
            [g_rotateBtn removeFromSuperview];
            g_rotateBtn = nil;
        }
        if (g_buttonWindow) {
            g_buttonWindow.hidden = YES;
            g_buttonWindow = nil;
        }
    });
}

// ===== GetFrame =====
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
+ (void)setupAudioInjectionWithFormat:(AudioStreamBasicDescription)format;
@end

@implementation GetFrame

+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew {
    @try {
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
            if (nowTime - renewTime > 3) { renewTime = nowTime; g_bufferReload = YES; }
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
            } @catch (NSException *except) { NSLog(@"[VCAM] 初始化读取视频出错:%@", except); }
        }

        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];

        CMSampleBufferRef newsampleBuffer = nil;
        switch(subMediaType) {
            case kCVPixelFormatType_32BGRA:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer); break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer); break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer); break;
            default:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
        }
        if (videoTrackout_32BGRA_Buffer) CFRelease(videoTrackout_32BGRA_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);

        if (newsampleBuffer == nil) {
            g_bufferReload = YES;
        } else {
            if (sampleBuffer) CFRelease(sampleBuffer);

            // 只做旋转，不做缩放
            if (fabs(g_userRotation) > 0.001) {
                CVPixelBufferRef srcPixels = CMSampleBufferGetImageBuffer(newsampleBuffer);
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (srcPixels && (now - g_lastRotationTime) >= ROTATION_THROTTLE) {
                    g_lastRotationTime = now;
                    CVPixelBufferRef rotated = rotatePixelBufferOnly(srcPixels, g_userRotation);
                    if (rotated) {
                        CMSampleTimingInfo timing = {0};
                        CMSampleBufferGetSampleTimingInfo(newsampleBuffer, 0, &timing);
                        CMVideoFormatDescriptionRef fmt = nil;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, rotated, &fmt);
                        CMSampleBufferRef rotatedBuffer = nil;
                        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, rotated, true, nil, nil, fmt, &timing, &rotatedBuffer);
                        if (fmt) CFRelease(fmt);
                        CVPixelBufferRelease(rotated);
                        if (rotatedBuffer) {
                            CFRelease(newsampleBuffer);
                            newsampleBuffer = rotatedBuffer;
                        }
                    }
                }
            }

            if (originSampleBuffer != nil) {
                CMSampleBufferRef copyBuffer = nil;
                CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);
                CMSampleTimingInfo sampleTime = {
                    .duration = CMSampleBufferGetDuration(originSampleBuffer),
                    .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                    .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
                };
                CMVideoFormatDescriptionRef videoInfo = nil;
                CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
                if (copyBuffer) {
                    CFDictionaryRef exif = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                    CFDictionaryRef tiff = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
                    if (exif) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exif, kCMAttachmentMode_ShouldPropagate);
                    if (tiff) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", tiff, kCMAttachmentMode_ShouldPropagate);
                    sampleBuffer = copyBuffer;
                }
                CFRelease(newsampleBuffer);
            } else {
                sampleBuffer = newsampleBuffer;
            }
        }
        if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
        return nil;
    } @catch (NSException *e) {
        NSLog(@"[VCAM] getCurrentFrame 异常: %@", e);
        return nil;
    }
}

+ (void)setupAudioInjectionWithFormat:(AudioStreamBasicDescription)format {
    if (g_audioInjectionReady || !g_audioEnabled) return;
    if (![g_fileManager fileExistsAtPath:g_tempFile]) return;
    @try {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
        AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!audioTrack) return;
        NSDictionary *outputSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(format.mSampleRate),
            AVNumberOfChannelsKey: @(format.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @(NO),
            AVLinearPCMIsNonInterleaved: @(NO),
        };
        g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        g_audioReplacementOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:outputSettings];
        g_audioReplacementOutput.alwaysCopiesSampleData = NO;
        if ([g_audioReader canAddOutput:g_audioReplacementOutput]) {
            [g_audioReader addOutput:g_audioReplacementOutput];
            [g_audioReader startReading];
            g_micAudioFormat = format;
            g_audioInjectionReady = YES;
            if (g_audioRingBuffer == NULL) g_audioRingBuffer = (int16_t *)calloc(AUDIO_RING_BUFFER_SIZE, sizeof(int16_t));
            g_audioRingBufferReadPos = 0;
            g_audioRingBufferWritePos = 0;
            g_audioRingBufferAvailable = 0;
            while (g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE - 4800) {
                CMSampleBufferRef buf = [g_audioReplacementOutput copyNextSampleBuffer];
                if (!buf) break;
                CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(buf);
                if (bb) {
                    size_t len = 0;
                    char *ptr = NULL;
                    CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &ptr);
                    if (ptr && len > 0) {
                        int samples = (int)(len / sizeof(int16_t));
                        int16_t *src = (int16_t *)ptr;
                        for (int i = 0; i < samples && g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE; i++) {
                            g_audioRingBuffer[g_audioRingBufferWritePos] = src[i];
                            g_audioRingBufferWritePos = (g_audioRingBufferWritePos + 1) % AUDIO_RING_BUFFER_SIZE;
                            g_audioRingBufferAvailable++;
                        }
                    }
                }
                CFRelease(buf);
            }
        }
    } @catch (NSException *e) { NSLog(@"[VCAM] 音频注入初始化失败: %@", e); }
}

+ (UIWindow*)getKeyWindow {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) { keyWindow = window; break; }
    }
    return keyWindow;
}
@end

// ===== 视频 Hook =====
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
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
        });
    }
}

%new
- (void)step:(CADisplayLink *)sender {
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
        g_previewLayer.frame = self.bounds;
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
%end

%hook AVCaptureSession
- (void)startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_lastBufferRefreshTime = [[NSDate date] timeIntervalSince1970];
    g_refreshPreviewByVideoDataOutputTime = g_lastBufferRefreshTime * 1000;
    // 只在相机启动时显示按钮
    if ([g_fileManager fileExistsAtPath:g_tempFile]) showRotateButton();
    %orig;
}
- (void)stopRunning {
    g_cameraRunning = NO;
    // 相机停止时隐藏按钮
    hideRotateButton();
    %orig;
}
- (void)addInput:(AVCaptureDeviceInput *)input {
    if ([[input device] position] > 0) g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
    %orig;
}
- (void)addOutput:(AVCaptureOutput *)output { %orig; }
%end

%hook AVCaptureStillImageOutput
- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler {
    g_canReleaseBuffer = NO;
    void (^newHandler)(CMSampleBufferRef imageDataSampleBuffer, NSError *error) = ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
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
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}
%end

%hook AVCapturePhotoOutput
+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer {
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings == nil || delegate == nil) return %orig;
    if (g_isIOS15OrLater) {
        if (@available(iOS 15.0, *)) {
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                static NSMutableArray *hooked; if (!hooked) hooked = [NSMutableArray new];
                NSString *cls = NSStringFromClass([delegate class]);
                if (![hooked containsObject:cls]) {
                    [hooked addObject:cls];
                    __block void (*orig)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *) = nil;
                    MSHookMessageEx([delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:), imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *co, AVCapturePhoto *ph, NSError *er) {
                        @try {
                            if (![g_fileManager fileExistsAtPath:g_tempFile]) return orig(self, @selector(captureOutput:didFinishProcessingPhoto:error:), co, ph, er);
                            g_canReleaseBuffer = NO;
                            static CMSampleBufferRef cb = nil;
                            CMSampleBufferRef tb = nil; CVPixelBufferRef tp = ph.pixelBuffer;
                            CMSampleTimingInfo st = {0}; CMVideoFormatDescriptionRef vi = nil;
                            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tp, &vi);
                            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tp, true, nil, nil, vi, &st, &tb);
                            CMSampleBufferRef nb = [GetFrame getCurrentFrame:tb :YES];
                            if (tb) CFRelease(tb);
                            if (nb) {
                                if (cb) CFRelease(cb);
                                CMSampleBufferCreateCopy(kCFAllocatorDefault, nb, &cb);
                                __block CVImageBufferRef ib = CMSampleBufferGetImageBuffer(cb);
                                CIImage *ci = [CIImage imageWithCVImageBuffer:ib];
                                UIImage *ui = [UIImage imageWithCIImage:ci];
                                __block NSData *nd = UIImageJPEGRepresentation(ui, 1);
                                __block NSData *(*fdrwc)(id, SEL, id<AVCapturePhotoFileDataRepresentationCustomizer>) = nil;
                                MSHookMessageEx([ph class], @selector(fileDataRepresentationWithCustomizer:), imp_implementationWithBlock(^(id s, id<AVCapturePhotoFileDataRepresentationCustomizer> c) {
                                    if ([g_fileManager fileExistsAtPath:g_tempFile]) return nd;
                                    return fdrwc(s, @selector(fileDataRepresentationWithCustomizer:), c);
                                }), (IMP*)&fdrwc);
                                __block NSData *(*fdr)(id, SEL) = nil;
                                MSHookMessageEx([ph class], @selector(fileDataRepresentation), imp_implementationWithBlock(^(id s, SEL c) {
                                    if ([g_fileManager fileExistsAtPath:g_tempFile]) return nd;
                                    return fdr(s, @selector(fileDataRepresentation));
                                }), (IMP*)&fdr);
                            }
                            g_canReleaseBuffer = YES;
                        } @catch (NSException *e) {
                            NSLog(@"[VCAM] photo hook 异常: %@", e);
                        }
                        return orig(self, @selector(captureOutput:didFinishProcessingPhoto:error:), co, ph, er);
                    }), (IMP*)&orig);
                }
            }
        }
    }
    %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!delegate || !queue) return %orig;
    static NSMutableArray *hooked; if (!hooked) hooked = [NSMutableArray new];
    NSString *cls = NSStringFromClass([delegate class]);
    if (![hooked containsObject:cls]) {
        [hooked addObject:cls];
        __block void (*orig)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
        MSHookMessageEx([delegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:), imp_implementationWithBlock(^(id self, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *c) {
            @try {
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                CMSampleBufferRef nb = [GetFrame getCurrentFrame:sb :NO];
                g_photoOrientation = [c videoOrientation];
                if (nb && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:nb];
                }
                return orig(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), o, nb ?: sb, c);
            } @catch (NSException *e) {
                NSLog(@"[VCAM] videoDataOutput hook 异常: %@", e);
                return orig(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), o, sb, c);
            }
        }), (IMP*)&orig);
    }
    %orig;
}
%end

// ===== 音频 Hook =====
static OSStatus (*AudioUnitRender_orig)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *) = NULL;

static OSStatus AudioUnitRender_hook(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = AudioUnitRender_orig(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    @try {
        if (status != noErr || inOutputBusNumber != 1 || !g_audioEnabled) return status;
        if (!g_audioInjectionReady) {
            if (ioData && ioData->mNumberBuffers > 0) {
                AudioBuffer *buf = &ioData->mBuffers[0];
                g_micAudioFormat.mSampleRate = 44100.0;
                g_micAudioFormat.mChannelsPerFrame = buf->mNumberChannels;
                g_micAudioFormat.mBitsPerChannel = 16;
                g_micAudioFormat.mFormatID = kAudioFormatLinearPCM;
                g_micAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                g_micAudioFormat.mBytesPerFrame = g_micAudioFormat.mChannelsPerFrame * sizeof(int16_t);
                g_micAudioFormat.mFramesPerPacket = 1;
                g_micAudioFormat.mBytesPerPacket = g_micAudioFormat.mBytesPerFrame;
                [GetFrame setupAudioInjectionWithFormat:g_micAudioFormat];
            }
            if (!g_audioInjectionReady) return status;
        }
        if (ioData && ioData->mNumberBuffers > 0) {
            AudioBuffer *buf = &ioData->mBuffers[0];
            int16_t *out = (int16_t *)buf->mData;
            int need = inNumberFrames * buf->mNumberChannels;
            for (int i = 0; i < need; i++) {
                if (g_audioRingBufferAvailable > 0) {
                    out[i] = g_audioRingBuffer[g_audioRingBufferReadPos];
                    g_audioRingBufferReadPos = (g_audioRingBufferReadPos + 1) % AUDIO_RING_BUFFER_SIZE;
                    g_audioRingBufferAvailable--;
                } else out[i] = 0;
            }
            if (g_audioRingBufferAvailable < 4800) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    if (!g_audioReplacementOutput || !g_audioReader) return;
                    while (g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE - 4800) {
                        CMSampleBufferRef ab = [g_audioReplacementOutput copyNextSampleBuffer];
                        if (!ab) { [g_audioReader cancelReading]; g_audioReader = nil; g_audioReplacementOutput = nil; g_audioInjectionReady = NO; return; }
                        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(ab);
                        if (bb) {
                            size_t len = 0; char *ptr = NULL;
                            CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &ptr);
                            if (ptr && len > 0) {
                                int samples = (int)(len / sizeof(int16_t));
                                int16_t *src = (int16_t *)ptr;
                                for (int i = 0; i < samples && g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE; i++) {
                                    g_audioRingBuffer[g_audioRingBufferWritePos] = src[i];
                                    g_audioRingBufferWritePos = (g_audioRingBufferWritePos + 1) % AUDIO_RING_BUFFER_SIZE;
                                    g_audioRingBufferAvailable++;
                                }
                            }
                        }
                        CFRelease(ab);
                    }
                });
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] 音频 hook 异常: %@", e);
    }
    return status;
}

// ===== 初始化 =====
%ctor {
    g_isMirroredMark = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/vcam_is_mirrored_mark")];
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}]) g_isIOS15OrLater = YES;
    g_fileManager = [NSFileManager defaultManager];
    g_pasteboard = [UIPasteboard generalPasteboard];

    loadUserRotation();
    updatePreferences();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    MSHookFunction((void *)AudioUnitRender, (void *)AudioUnitRender_hook, (void **)&AudioUnitRender_orig);
}

%dtor {
    g_fileManager = nil; g_pasteboard = nil;
    g_canReleaseBuffer = YES; g_bufferReload = YES;
    g_previewLayer = nil; g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    if (g_audioRingBuffer) { free(g_audioRingBuffer); g_audioRingBuffer = NULL; }
    g_audioReader = nil; g_audioReplacementOutput = nil; g_audioInjectionReady = NO;
    g_rotateBtn = nil;
    g_buttonWindow = nil;
}