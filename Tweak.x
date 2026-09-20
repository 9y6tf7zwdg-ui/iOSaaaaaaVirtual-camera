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
    if (preferences && [preferences objectForKey:key]) {
        return [[preferences objectForKey:key] boolValue];
    }
    return defaultValue;
}

static void updatePreferences() {
    loadPreferences();
    g_audioEnabled = getBoolFromPreferences(@"enableAudio", YES);
}

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    updatePreferences();
}

// ===== 音频注入辅助函数 =====
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
            [g_audioReader cancelReading];
            g_audioReader = nil;
            g_audioReplacementOutput = nil;
            g_audioInjectionReady = NO;
            return;
        }

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(audioBuffer);
        if (blockBuffer) {
            size_t totalLength = 0;
            char *dataPointer = NULL;
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
            ensureRingBufferAllocated();
            g_audioRingBufferReadPos = 0;
            g_audioRingBufferWritePos = 0;
            g_audioRingBufferAvailable = 0;
            fillRingBufferFromVideo();
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] 音频注入初始化失败: %@", e);
    }
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
                NSLog(@"[VCAM] 初始化读取视频出错:%@", except);
            }
        }

        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];

        CMSampleBufferRef newsampleBuffer = nil;
        switch(subMediaType) {
            case kCVPixelFormatType_32BGRA:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer);
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                break;
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
        }

        if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
        return nil;
    } @catch (NSException *e) {
        NSLog(@"[VCAM] getCurrentFrame 异常: %@", e);
        return nil;
    }
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
            [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
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
                static NSMutableArray *hooked;
                if (hooked == nil) hooked = [NSMutableArray new];
                NSString *className = NSStringFromClass([delegate class]);
                if ([hooked containsObject:className] == NO) {
                    [hooked addObject:className];
                    __block void (*original_method)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *) = nil;
                    MSHookMessageEx([delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:), imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) {
                        @try {
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
                                UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                                __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);

                                __block NSData *(*fileDataRepresentationWithCustomizer)(id, SEL, id<AVCapturePhotoFileDataRepresentationCustomizer>) = nil;
                                MSHookMessageEx([photo class], @selector(fileDataRepresentationWithCustomizer:), imp_implementationWithBlock(^(id s, id<AVCapturePhotoFileDataRepresentationCustomizer> c) {
                                    if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                    return fileDataRepresentationWithCustomizer(s, @selector(fileDataRepresentationWithCustomizer:), c);
                                }), (IMP*)&fileDataRepresentationWithCustomizer);

                                __block NSData *(*fileDataRepresentation)(id, SEL) = nil;
                                MSHookMessageEx([photo class], @selector(fileDataRepresentation), imp_implementationWithBlock(^(id s, SEL c) {
                                    if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                    return fileDataRepresentation(s, @selector(fileDataRepresentation));
                                }), (IMP*)&fileDataRepresentation);
                            }
                            g_canReleaseBuffer = YES;
                        } @catch (NSException *e) {
                            NSLog(@"[VCAM] photo hook 异常: %@", e);
                        }
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
        __block void (*original_method)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
        MSHookMessageEx([sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:), imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
            @try {
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];
                g_photoOrientation = [connection videoOrientation];
                if (newBuffer && g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                }
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer ?: sampleBuffer, connection);
            } @catch (NSException *e) {
                NSLog(@"[VCAM] videoDataOutput hook 异常: %@", e);
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }
        }), (IMP*)&original_method);
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
                setupAudioInjectionWithFormat(g_micAudioFormat);
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
                } else {
                    out[i] = 0;
                }
            }
            if (g_audioRingBufferAvailable < 4800) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    fillRingBufferFromVideo();
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

    updatePreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    prefsChanged,
                                    CFSTR("com.trizau.sileo.vcam.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    MSHookFunction((void *)AudioUnitRender, (void *)AudioUnitRender_hook, (void **)&AudioUnitRender_orig);
}

%dtor {
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    if (g_audioRingBuffer) {
        free(g_audioRingBuffer);
        g_audioRingBuffer = NULL;
    }
    g_audioReader = nil;
    g_audioReplacementOutput = nil;
    g_audioInjectionReady = NO;
}