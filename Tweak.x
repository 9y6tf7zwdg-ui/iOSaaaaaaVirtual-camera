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
static AVAssetReaderVideoCompositionOutput *videoTrackout = nil;

static NSTimeInterval g_lastBufferRefreshTime = 0;
static const NSTimeInterval BUFFER_REFRESH_INTERVAL = 30.0;
static BOOL g_isIOS15OrLater = NO;

NSString *g_isMirroredMark = nil;
NSString *g_tempFile = nil;

@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
@end

@implementation GetFrame

+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable)originSampleBuffer :(BOOL)forceReNew {
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
            if (!videoTrack) {
                NSLog(@"[VCAM] 视频没有视频轨");
                return nil;
            }

            // ⭐ 核心：使用 AVAssetReaderVideoCompositionOutput，让系统自动处理视频方向
            AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:asset];
            // 保证帧率合适，避免过高帧率导致性能问题
            videoComposition.frameDuration = CMTimeMake(1, 30);

            NSDictionary *outputSettings = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };

            videoTrackout = [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[videoTrack]
                                                                               videoSettings:outputSettings];
            videoTrackout.videoComposition = videoComposition;
            videoTrackout.alwaysCopiesSampleData = NO;

            if ([reader canAddOutput:videoTrackout]) {
                [reader addOutput:videoTrackout];
                [reader startReading];
            } else {
                NSLog(@"[VCAM] 无法添加 videoCompositionOutput");
                return nil;
            }
        } @catch (NSException *except) {
            NSLog(@"[VCAM] 初始化读取视频出错:%@", except);
        }
    }

    CMSampleBufferRef newsampleBuffer = [videoTrackout copyNextSampleBuffer];

    if (newsampleBuffer == nil) {
        g_bufferReload = YES;
        if (sampleBuffer) {
            CFRelease(sampleBuffer);
            sampleBuffer = nil;
        }
        return nil;
    }

    if (sampleBuffer) CFRelease(sampleBuffer);

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
        if (videoInfo) CFRelease(videoInfo);

        if (copyBuffer) {
            CFDictionaryRef exifAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
            CFDictionaryRef TIFFAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
            if (exifAttachments) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exifAttachments, kCMAttachmentMode_ShouldPropagate);
            if (exifAttachments) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", TIFFAttachments, kCMAttachmentMode_ShouldPropagate);
            sampleBuffer = copyBuffer;
        }
        CFRelease(newsampleBuffer);
    } else {
        sampleBuffer = newsampleBuffer;
    }

    if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
    return nil;
}

+ (UIWindow*)getKeyWindow {
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
            // 使用 AspectFit 完整显示视频，避免裁剪，让用户看到整个视频画面
            [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
        }
    } else {
        if (g_maskLayer) g_maskLayer.opacity = 0;
        if (g_previewLayer) g_previewLayer.opacity = 0;
    }
    if (g_cameraRunning && g_previewLayer) {
        g_previewLayer.frame = self.bounds;
        switch(g_photoOrientation) {
            case AVCaptureVideoOrientationPortrait:
            case AVCaptureVideoOrientationPortraitUpsideDown:
                g_previewLayer.transform = CATransform3DMakeRotation(0, 0, 0, 1);
                break;
            case AVCaptureVideoOrientationLandscapeRight:
                g_previewLayer.transform = CATransform3DMakeRotation(M_PI_2, 0, 0, 1);
                break;
            case AVCaptureVideoOrientationLandscapeLeft:
                g_previewLayer.transform = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1);
                break;
            default:
                g_previewLayer.transform = self.transform;
        }
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            static CMSampleBufferRef copyBuffer = nil;
            if (nowTime - refreshTime > 1000 / 33 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                g_photoOrientation = -1;
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
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation) {
                case AVCaptureVideoOrientationPortrait:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];
                    break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                    break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
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
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation) {
                case AVCaptureVideoOrientationPortrait:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];
                    break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                    break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings == nil || delegate == nil) return %orig;
    if (g_isIOS15OrLater) {
        if (@available(iOS 15.0, *)) {
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                static NSMutableArray *hooked;
                if (hooked == nil) hooked = [NSMutableArray new];
                NSString *className = NSStringFromClass([delegate class]);
                if ([hooked containsObject:className] == NO) {
                    [hooked addObject:className];
                    __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) = nil;
                    MSHookMessageEx([delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:), imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) {
                        if (![g_fileManager fileExistsAtPath:g_tempFile]) {
                            return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                        }
                        g_canReleaseBuffer = NO;
                        static CMSampleBufferRef copyBuffer = nil;
                        CMSampleBufferRef tempBuffer = nil;
                        CVPixelBufferRef tempPixelBuffer = photo.pixelBuffer;
                        CMSampleTimingInfo sampleTime = {0};
                        CMVideoFormatDescriptionRef videoInfo = nil;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, &videoInfo);
                        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &tempBuffer);
                        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:tempBuffer :YES];
                        if (tempBuffer) CFRelease(tempBuffer);
                        if (newBuffer) {
                            if (copyBuffer) CFRelease(copyBuffer);
                            CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                            __block CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(copyBuffer);
                            CIImage *ciimage = [CIImage imageWithCVImageBuffer:imageBuffer];
                            CIImage *ciimageRotate = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                            CIContext *cicontext = [CIContext new];
                            __block CGImageRef _Nullable cgimage = [cicontext createCGImage:ciimageRotate fromRect:ciimageRotate.extent];
                            UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                            __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);

                            __block NSData *(*fileDataRepresentationWithCustomizer)(id self, SEL _cmd, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer);
                            MSHookMessageEx([photo class], @selector(fileDataRepresentationWithCustomizer:), imp_implementationWithBlock(^(id self, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentationWithCustomizer(self, @selector(fileDataRepresentationWithCustomizer:), customizer);
                            }), (IMP*)&fileDataRepresentationWithCustomizer);

                            __block NSData *(*fileDataRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(fileDataRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentation(self, @selector(fileDataRepresentation));
                            }), (IMP*)&fileDataRepresentation);

                            __block CVPixelBufferRef *(*previewPixelBuffer)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(previewPixelBuffer), imp_implementationWithBlock(^(id self, SEL _cmd) {
                                return nil;
                            }), (IMP*)&previewPixelBuffer);

                            __block CVImageBufferRef (*pixelBuffer)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(pixelBuffer), imp_implementationWithBlock(^(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return imageBuffer;
                                return pixelBuffer(self, @selector(pixelBuffer));
                            }), (IMP*)&pixelBuffer);

                            __block CGImageRef _Nullable(*CGImageRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(CGImageRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return CGImageRepresentation(self, @selector(CGImageRepresentation));
                            }), (IMP*)&CGImageRepresentation);

                            __block CGImageRef _Nullable(*previewCGImageRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(previewCGImageRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd) {
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return previewCGImageRepresentation(self, @selector(previewCGImageRepresentation));
                            }), (IMP*)&previewCGImageRepresentation);
                        }
                        g_canReleaseBuffer = YES;
                        return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                    }), (IMP*)&original_method);
                }
            }
        }
    }
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
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;
        MSHookMessageEx([sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:), imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
            g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];
            g_photoOrientation = [connection videoOrientation];
            if (newBuffer && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                [g_previewLayer flush];
                [g_previewLayer enqueueSampleBuffer:newBuffer];
            }
            return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer ?: sampleBuffer, connection);
        }), (IMP*)&original_method);
    }
    %orig;
}
%end

%ctor {
    g_isMirroredMark = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/vcam_is_mirrored_mark")];
    g_tempFile = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];

    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}]) g_isIOS15OrLater = YES;
    g_fileManager = [NSFileManager defaultManager];
}

%dtor {
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
}