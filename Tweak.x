#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <roothide.h>
#import <substrate.h>

static NSFileManager *g_fileManager = nil;
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

// ===== 用户旋转角度 =====
static CGFloat g_userRotation = 0;

// ===== CIContext 串行队列保护 =====
static CIContext *g_ciContext = nil;
static dispatch_queue_t g_ciQueue = nil;

// ===== 输出缓冲池 =====
static CVPixelBufferPoolRef g_outputPool = NULL;
static size_t g_poolWidth = 0;
static size_t g_poolHeight = 0;

// ===== 音频注入 =====
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

// ===== 帧率节流 =====
static NSTimeInterval g_lastRotationTime = 0;
static const NSTimeInterval ROTATION_THROTTLE = 1.0 / 30.0;

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

// ===== 创建输出缓冲池 =====
static void ensureOutputPool(size_t width, size_t height) {
    if (g_outputPool && g_poolWidth == width && g_poolHeight == height) return;
    if (g_outputPool) {
        CVPixelBufferPoolRelease(g_outputPool);
        g_outputPool = NULL;
    }
    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        (id)kCVPixelBufferPoolAllocationThresholdKey: @5,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    NSDictionary *bufferAttrs = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn ret = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                            (__bridge CFDictionaryRef)poolAttrs,
                                            (__bridge CFDictionaryRef)bufferAttrs,
                                            &g_outputPool);
    if (ret != kCVReturnSuccess) {
        g_outputPool = NULL;
        return;
    }
    g_poolWidth = width;
    g_poolHeight = height;
}

// ===== 旋转 + 缩放到目标尺寸 =====
static CVPixelBufferRef processPixelBuffer(CVPixelBufferRef src, CGFloat angleRadians, size_t targetW, size_t targetH) {
    if (!src || targetW == 0 || targetH == 0) return NULL;
    __block CVPixelBufferRef result = NULL;
    @try {
        dispatch_sync(g_ciQueue, ^{
            @try {
                if (!g_ciContext) return;
                CIImage *img = [CIImage imageWithCVPixelBuffer:src];

                if (fabs(angleRadians) > 0.001) {
                    CGAffineTransform t = CGAffineTransformMakeRotation(angleRadians);
                    img = [img imageByApplyingTransform:t];
                }

                CGRect extent = img.extent;
                if (extent.origin.x != 0 || extent.origin.y != 0) {
                    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
                    extent = img.extent;
                }
                if (extent.size.width <= 0 || extent.size.height <= 0) return;

                CGFloat scaleX = (CGFloat)targetW / extent.size.width;
                CGFloat scaleY = (CGFloat)targetH / extent.size.height;
                CGFloat scale = MIN(scaleX, scaleY);
                img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
                extent = img.extent;

                CGFloat offsetX = ((CGFloat)targetW - extent.size.width) / 2.0;
                CGFloat offsetY = ((CGFloat)targetH - extent.size.height) / 2.0;
                img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];

                ensureOutputPool(targetW, targetH);
                CVPixelBufferRef dst = NULL;
                if (g_outputPool) {
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_outputPool, &dst);
                }
                if (!dst) {
                    NSDictionary *opts = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                    CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)opts, &dst);
                }
                if (!dst) return;

                [g_ciContext render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, targetW, targetH) colorSpace:NULL];
                result = dst;
            } @catch (NSException *e) { NSLog(@"[VCAM] process 异常: %@", e); }
        });
    } @catch (NSException *e) { NSLog(@"[VCAM] dispatch 异常: %@", e); }
    return result;
}

// ===== 音频注入初始化 =====
static void ensureRingBufferAllocated() {
    if (g_audioRingBuffer == NULL) {
        g_audioRingBuffer = (int16_t *)calloc(AUDIO_RING_BUFFER_SIZE, sizeof(int16_t));
    }
}
static void fillRingBufferFromVideo() {
    if (!g_audioReplacementOutput || !g_audioReader) return;
    ensureRingBufferAllocated();
    while (g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE - 4800) {
        CMSampleBufferRef audioBuffer = [g_audioReplacementOutput copyNextSampleBuffer];
        if (!audioBuffer) {
            [g_audioReader cancelReading]; g_audioReader = nil; g_audioReplacementOutput = nil; g_audioInjectionReady = NO; return;
        }
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(audioBuffer);
        if (blockBuffer) {
            size_t totalLength = 0; char *dataPointer = NULL;
            CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
            if (dataPointer && totalLength > 0) {
                int samples = (int)(totalLength / sizeof(int16_t));
                int16_t *srcData = (int16_t *)dataPointer;
                for (int i = 0; i < samples && g_audioRingBufferAvailable < AUDIO_RING_BUFFER_SIZE; i++) {
                    g_audioRingBuffer[g_audioRingBufferWritePos] = srcData[i];
                    g_audioRingBufferWritePos = (g_audioRingBufferWritePos + 1) % AUDIO_RING_BUFFER_SIZE;
                    g_audioRingBufferAvailable++;
                }
            }
        }
        CFRelease(audioBuffer);
    }
}
static void setupAudioInjectionWithFormat(AudioStreamBasicDescription format) {
    if (g_audioInjectionReady || !g_audioEnabled) return;
    if (![g_fileManager fileExistsAtPath:g_tempFile]) return;
    @try {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
        AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!audioTrack) return;
        NSDictionary *outputSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(format.mSampleRate),
            AVNumberOfChannelsKey: @(format.mChannelsPerFrame), AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @(NO), AVLinearPCMIsNonInterleaved: @(NO),
        };
        g_audioReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        g_audioReplacementOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:outputSettings];
        g_audioReplacementOutput.alwaysCopiesSampleData = NO;
        if ([g_audioReader canAddOutput:g_audioReplacementOutput]) {
            [g_audioReader addOutput:g_audioReplacementOutput];
            [g_audioReader startReading];
            g_micAudioFormat = format; g_audioInjectionReady = YES;
            ensureRingBufferAllocated();
            g_audioRingBufferReadPos = 0; g_audioRingBufferWritePos = 0; g_audioRingBufferAvailable = 0;
            fillRingBufferFromVideo();
        }
    } @catch (NSException *e) { NSLog(@"[VCAM] 音频注入初始化失败: %@", e); }
}

// ===== 悬浮按钮 =====
static UIWindow *g_buttonWindow = nil;
static UIButton *g_rotateBtn = nil;

@interface VCAMButtonHandler : NSObject
+ (instancetype)shared;
- (void)cycle:(UIButton *)btn;
- (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation VCAMButtonHandler
+ (instancetype)shared {
    static VCAMButtonHandler *h = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [VCAMButtonHandler new]; }); return h;
}
- (void)cycle:(UIButton *)btn {
    if (fabs(g_userRotation) < 0.01) saveUserRotation(M_PI_2);
    else if (fabs(g_userRotation - M_PI_2) < 0.01) saveUserRotation(M_PI);
    else if (fabs(g_userRotation - M_PI) < 0.01) saveUserRotation(-M_PI_2);
    else saveUserRotation(0);
    [btn setTitle:rotationLabel(g_userRotation) forState:UIControlStateNormal];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void showRotateButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_rotateBtn) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
        }
        if (!scene) return;
        if (!g_buttonWindow) {
            g_buttonWindow = [[UIWindow alloc] initWithWindowScene:scene];
            g_buttonWindow.windowLevel = UIWindowLevelAlert + 2000; g_buttonWindow.backgroundColor = [UIColor clearColor];
            g_buttonWindow.hidden = NO; g_buttonWindow.userInteractionEnabled = YES;
            UIViewController *rootVC = [[UIViewController alloc] init]; rootVC.view.backgroundColor = [UIColor clearColor];
            g_buttonWindow.rootViewController = rootVC;
        }
        CGFloat w = 54;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(g_buttonWindow.bounds.size.width - w - 15, 100, w, w);
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        btn.layer.cornerRadius = w / 2.0; btn.layer.borderWidth = 1.0; btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [btn setTitle:rotationLabel(g_userRotation) forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [btn addTarget:[VCAMButtonHandler shared] action:@selector(cycle:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[VCAMButtonHandler shared] action:@selector(pan:)];
        [btn addGestureRecognizer:pan]; [g_buttonWindow addSubview:btn]; g_rotateBtn = btn;
    });
}
static void hideRotateButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_rotateBtn) { [g_rotateBtn removeFromSuperview]; g_rotateBtn = nil; }
        if (g_buttonWindow) { g_buttonWindow.hidden = YES; g_buttonWindow = nil; }
    });
}

// ===== GetFrame =====
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
@end
@implementation GetFrame
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew {
    @try {
        static CMSampleBufferRef sampleBuffer = nil;
        CMFormatDescriptionRef formatDescription = nil;
        CMMediaType mediaType = -1; CMMediaType subMediaType = -1;
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
                [reader addOutput:videoTrackout_32BGRA]; [reader addOutput:videoTrackout_420YpCbCr8BiPlanarVideoRange]; [reader addOutput:videoTrackout_420YpCbCr8BiPlanarFullRange];
                [reader startReading];
            } @catch (NSException *except) { NSLog(@"[VCAM] 初始化读取视频出错:%@", except); }
        }
        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];
        CMSampleBufferRef newsampleBuffer = nil;
        switch(subMediaType) {
            case kCVPixelFormatType_32BGRA: CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer); break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer); break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer); break;
            default: CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
        }
        if (videoTrackout_32BGRA_Buffer) CFRelease(videoTrackout_32BGRA_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);
        if (newsampleBuffer == nil) { g_bufferReload = YES; }
        else {
            if (sampleBuffer) CFRelease(sampleBuffer);
            if (originSampleBuffer != nil) {
                CVImageBufferRef originPixels = CMSampleBufferGetImageBuffer(originSampleBuffer);
                if (originPixels) {
                    size_t targetW = CVPixelBufferGetWidth(originPixels);
                    size_t targetH = CVPixelBufferGetHeight(originPixels);
                    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                    if ((now - g_lastRotationTime) >= ROTATION_THROTTLE) {
                        g_lastRotationTime = now;
                        CVPixelBufferRef srcPixels = CMSampleBufferGetImageBuffer(newsampleBuffer);
                        CVPixelBufferRef processed = processPixelBuffer(srcPixels, g_userRotation, targetW, targetH);
                        if (processed) {
                            CMSampleTimingInfo timing = {0}; CMSampleBufferGetSampleTimingInfo(newsampleBuffer, 0, &timing);
                            CMVideoFormatDescriptionRef fmt = nil; CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, processed, &fmt);
                            CMSampleBufferRef processedBuffer = nil;
                            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, processed, true, nil, nil, fmt, &timing, &processedBuffer);
                            if (fmt) CFRelease(fmt); CVPixelBufferRelease(processed);
                            if (processedBuffer) { CFRelease(newsampleBuffer); newsampleBuffer = processedBuffer; }
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
                CMVideoFormatDescriptionRef videoInfo = nil; CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
                if (copyBuffer) {
                    CFDictionaryRef exif = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                    CFDictionaryRef tiff = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
                    if (exif) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exif, kCMAttachmentMode_ShouldPropagate);
                    if (tiff) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", tiff, kCMAttachmentMode_ShouldPropagate);
                    sampleBuffer = copyBuffer;
                }
                CFRelease(newsampleBuffer);
            } else { sampleBuffer = newsampleBuffer; }
        }
        if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
        return nil;
    } @catch (NSException *e) { NSLog(@"[VCAM] getCurrentFrame 异常: %@", e); return nil; }
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
        g_maskLayer = [CALayer new]; g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self insertSublayer:g_maskLayer above:layer]; [self insertSublayer:g_previewLayer above:g_maskLayer];
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
        if (g_previewLayer) { g_previewLayer.opacity = 1; [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect]; }
    } else {
        if (g_maskLayer) g_maskLayer.opacity = 0;
        if (g_previewLayer) g_previewLayer.opacity = 0;
    }
    if (g_cameraRunning && g_previewLayer) {
        g_previewLayer.frame = self.bounds; g_previewLayer.transform = CATransform3DIdentity;
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
    if (currentTime - g_lastBufferRefreshTime > BUFFER_REFRESH_INTERVAL) { g_lastBufferRefreshTime = currentTime; g_bufferReload = YES; }
}
%end

%hook AVCaptureSession
- (void)startRunning {
    g_cameraRunning = YES; g_bufferReload = YES;
    g_lastBufferRefreshTime = [[NSDate date] timeIntervalSince1970];
    g_refreshPreviewByVideoDataOutputTime = g_lastBufferRefreshTime * 1000;
    if ([g_fileManager fileExistsAtPath:g_tempFile]) showRotateButton();
    %orig;
}
- (void)stopRunning { g_cameraRunning = NO; hideRotateButton(); %orig; }
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
        handler(imageDataSampleBuffer, error); g_canReleaseBuffer = YES;
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
    if (g_isIOS15OrLater && @available(iOS 15.0, *)) {
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
                        static CMSampleBufferRef cb = nil; CMSampleBufferRef tb = nil; CVPixelBufferRef tp = ph.pixelBuffer;
                        CMSampleTimingInfo st = {0}; CMVideoFormatDescriptionRef vi = nil;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tp, &vi);
                        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tp, true, nil, nil, vi, &st, &tb);
                        CMSampleBufferRef nb = [GetFrame getCurrentFrame:tb :YES]; if (tb) CFRelease(tb);
                        if (nb) {
                            if (cb) CFRelease(cb); CMSampleBufferCreateCopy(kCFAllocatorDefault, nb, &cb);
                            __block CVImageBufferRef ib = CMSampleBufferGetImageBuffer(cb);
                            CIImage *ci = [CIImage imageWithCVImageBuffer:ib]; UIImage *ui = [UIImage imageWithCIImage:ci];
                            __block NSData *nd = UIImageJPEGRepresentation(ui, 1);
                            __block NSData *(*fdrwc)(id, SEL, id<AVCapturePhotoFileDataRepresentationCustomizer>) = nil;
                            MSHookMessageEx([ph class], @selector(fileDataRepresentationWithCustomizer:), imp_implementationWithBlock(^(id s, id<AVCapturePhotoFileDataRepresentationCustomizer> c) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return nd; return fdrwc(s, @selector(fileDataRepresentationWithCustomizer:), c);
                            }), (IMP*)&fdrwc);
                            __block NSData *(*fdr)(id, SEL) = nil;
                            MSHookMessageEx([ph class], @selector(fileDataRepresentation), imp_implementationWithBlock(^(id s, SEL c) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return nd; return fdr(s, @selector(fileDataRepresentation));
                            }), (IMP*)&fdr);
                        }
                        g_canReleaseBuffer = YES;
                    } @catch (NSException *e) { NSLog(@"[VCAM] photo hook 异常: %@", e); }
                    return orig(self, @selector(captureOutput:didFinishProcessingPhoto:error:), co, ph, er);
                }), (IMP*)&orig);
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
                if (nb && g_previewLayer && g_previewLayer.readyForMoreMediaData) { [g_previewLayer flush]; [g_previewLayer enqueueSampleBuffer:nb]; }
                return orig(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), o, nb ?: sb, c);
            } @catch (NSException *e) { NSLog(@"[VCAM] videoDataOutput hook 异常: %@", e); return orig(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), o, sb, c); }
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
                g_micAudioFormat.mSampleRate = 44100.0; g_micAudioFormat.mChannelsPerFrame = buf->mNumberChannels;
                g_micAudioFormat.mBitsPerChannel = 16; g_micAudioFormat.mFormatID = kAudioFormatLinearPCM;
                g_micAudioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                g_micAudioFormat.mBytesPerFrame = g_micAudioFormat.mChannelsPerFrame * sizeof(int16_t);
                g_micAudioFormat.mFramesPerPacket = 1; g_micAudioFormat.mBytesPerPacket = g_micAudioFormat.mBytesPerFrame;
                setupAudioInjectionWithFormat(g_micAudioFormat);
            }
            if (!g_audioInjectionReady) return status;
        }
        if (ioData && ioData->mNumberBuffers > 0) {
            AudioBuffer *buf = &ioData->mBuffers[0]; int16_t *out = (int16_t *)buf->mData; int need = inNumberFrames * buf->mNumberChannels;
            for (int i = 0; i < need; i++) {
                if (g_audioRingBufferAvailable > 0) {
                    out[i] = g_audioRingBuffer[g_audioRingBufferReadPos];
                    g_audioRingBufferReadPos = (g_audioRingBufferReadPos + 1) % AUDIO_RING_BUFFER_SIZE; g_audioRingBufferAvailable--;
                } else out[i] = 0;
            }
            if (g_audioRingBufferAvailable < 4800) { dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ fillRingBufferFromVideo(); }); }
        }
    } @catch (NSException *e) { NSLog(@"[VCAM] 音频 hook 异常: %@", e); }
    return status;
}

// ===== 初始化 =====
%ctor {
    g_isMirroredMark = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/vcam_is_mirrored_mark")];
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}]) g_isIOS15OrLater = YES;
    g_fileManager = [NSFileManager defaultManager]; loadUserRotation();
    g_ciQueue = dispatch_queue_create("vcam.ci", DISPATCH_QUEUE_SERIAL); g_ciContext = [CIContext contextWithOptions:nil];
    updatePreferences();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    MSHookFunction((void *)AudioUnitRender, (void *)AudioUnitRender_hook, (void **)&AudioUnitRender_orig);
}
%dtor {
    g_fileManager = nil; g_canReleaseBuffer = YES; g_bufferReload = YES; g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0; g_cameraRunning = NO;
    if (g_outputPool) { CVPixelBufferPoolRelease(g_outputPool); g_outputPool = NULL; }
    g_ciContext = nil; g_ciQueue = nil;
    if (g_audioRingBuffer) { free(g_audioRingBuffer); g_audioRingBuffer = NULL; }
    g_audioReader = nil; g_audioReplacementOutput = nil; g_audioInjectionReady = NO; g_rotateBtn = nil; g_buttonWindow = nil;
}