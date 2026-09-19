#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "VCAMDebugLog.h"

#pragma mark - 诊断 AVCaptureVideoPreviewLayer 生命周期

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    VCAM_LOG(@"PreviewLayer initWithSession");
    return %orig;
}

- (void)setSession:(AVCaptureSession *)session {
    VCAM_LOG(@"PreviewLayer setSession");
    %orig;
}

- (void)addSublayer:(CALayer *)layer {
    VCAM_LOG(@"PreviewLayer addSublayer: %@", NSStringFromClass([layer class]));
    %orig;
}

- (void)didMoveToSuperlayer {
    VCAM_LOG(@"PreviewLayer didMoveToSuperlayer: superlayer=%@", NSStringFromClass([self.superlayer class]));
    %orig;
}

- (void)layoutSublayers {
    VCAM_LOG(@"PreviewLayer layoutSublayers count=%lu", (unsigned long)self.sublayers.count);
    for (CALayer *sub in self.sublayers) {
        VCAM_LOG(@"    sub: %@ frame=%@", NSStringFromClass([sub class]), NSStringFromCGRect(sub.frame));
    }
    %orig;
}

%end

#pragma mark - AVCaptureSession

static BOOL g_analyzerRunning = NO;

static void VCAMDumpLayerTree(CALayer *layer, int depth) {
    if (!layer) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];
    VCAM_LOG(@"%@- %@ zPos=%.1f opacity=%.2f frame=%@",
             indent,
             NSStringFromClass([layer class]),
             layer.zPosition,
             layer.opacity,
             NSStringFromCGRect(layer.frame));
    for (CALayer *sub in layer.sublayers) {
        VCAMDumpLayerTree(sub, depth + 1);
    }
}

static void VCAMStartPeriodicDump(void) {
    if (g_analyzerRunning) return;
    g_analyzerRunning = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            UIWindow *keyWindow = nil;
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (!keyWindow) return;
            VCAM_LOG(@"===== 图层树 dump =====");
            VCAMDumpLayerTree(keyWindow.layer, 0);
        }];
    });
}

%hook AVCaptureSession

- (void)addInput:(AVCaptureDeviceInput *)input {
    VCAM_LOG(@"Session addInput: %@", input.device.localizedName);
    %orig;
}

- (void)addOutput:(AVCaptureOutput *)output {
    VCAM_LOG(@"Session addOutput: %@", NSStringFromClass([output class]));
    %orig;
}

- (void)startRunning {
    VCAM_LOG(@"Session startRunning");
    %orig;
    VCAMStartPeriodicDump();
}

- (void)stopRunning {
    VCAM_LOG(@"Session stopRunning");
    %orig;
}

%end

#pragma mark - AVCaptureVideoDataOutput

%hook AVCaptureVideoDataOutput

SampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    VCAM_LOG(@"VideoDataOutput setSampleBufferDelegate: %@", NSStringFromClass([delegate class]));
    %orig;
}

%end

#pragma mark - CALayer 层操作诊断

%hook CALayer

- (void)addSublayer:(CALayer *)layer {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"addSublayer on %@: %@", NSStringFromClass([self class]), NSStringFromClass([layer class]));
    }
    %orig;
}

%end

%ctor {
    VCAM_LOG_STARTUP();
}