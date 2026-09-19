// 系统相机诊断插件
// 目的：搞清楚系统相机走哪条路径，找到正确的 Hook 点
// 使用时：打开设置 -> VCAM -> 打开"系统相机替换模式"，
//         然后打开系统相机，在 Xcode Console / 系统日志中观察输出

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>

#define VCAM_LOG(fmt, ...) NSLog(@"[VCAM-Analyzer] " fmt, ##__VA_ARGS__)

#pragma mark - 1. 诊断 AVCaptureVideoPreviewLayer 生命周期

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    VCAM_LOG(@"PreviewLayer initWithSession called, session=%p", session);
    return %orig;
}

- (void)setSession:(AVCaptureSession *)session {
    VCAM_LOG(@"PreviewLayer setSession called, session=%p", session);
    %orig;
}

- (void)addSublayer:(CALayer *)layer {
    VCAM_LOG(@"PreviewLayer addSublayer called, layer.class=%@", NSStringFromClass([layer class]));
    %orig;
}

- (void)didMoveToSuperlayer {
    VCAM_LOG(@"PreviewLayer didMoveToSuperlayer, superlayer=%@", NSStringFromClass([self.superlayer class]));
    %orig;
}

- (void)layoutSublayers {
    VCAM_LOG(@"PreviewLayer layoutSublayers, sublayers.count=%lu", (unsigned long)self.sublayers.count);
    for (CALayer *sub in self.sublayers) {
        VCAM_LOG(@"  子层: %@  frame=%@", NSStringFromClass([sub class]), NSStringFromCGRect(sub.frame));
    }
    %orig;
}

- (void)setFrame:(CGRect)frame {
    VCAM_LOG(@"PreviewLayer setFrame: %@", NSStringFromCGRect(frame));
    %orig;
}

%end

#pragma mark - 2. 诊断整个视图层级（每 2 秒 dump 一次）

static BOOL g_analyzerRunning = NO;

static void VCAMDumpViewHierarchy(UIView *view, int depth) {
    if (!view) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];

    VCAM_LOG(@"%@- %@  frame=%@  hidden=%d  alpha=%.2f",
             indent,
             NSStringFromClass([view class]),
             NSStringFromCGRect(view.frame),
             view.hidden,
             view.alpha);

    for (UIView *sub in view.subviews) {
        VCAMDumpViewHierarchy(sub, depth + 1);
    }
}

static void VCAMDumpLayerTree(CALayer *layer, int depth) {
    if (!layer) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];

    VCAM_LOG(@"%@- %@  frame=%@  opacity=%.2f  zPosition=%.1f",
             indent,
             NSStringFromClass([layer class]),
             NSStringFromCGRect(layer.frame),
             layer.opacity,
             layer.zPosition);

    for (CALayer *sub in layer.sublayers) {
        VCAMDumpLayerTree(sub, depth + 1);
    }
}

// 定时 dump 当前活跃窗口的视图层级
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

            VCAM_LOG(@"========== 视图层级 dump ==========");
            VCAMDumpViewHierarchy(keyWindow, 0);

            VCAM_LOG(@"========== 图层树 dump ==========");
            VCAMDumpLayerTree(keyWindow.layer, 0);
        }];
    });
}

#pragma mark - 3. 诊断 AVCaptureSession 的输入输出

%hook AVCaptureSession

- (void)addInput:(AVCaptureDeviceInput *)input {
    VCAM_LOG(@"Session addInput: device=%@", input.device.localizedName);
    %orig;
}

- (void)addOutput:(AVCaptureOutput *)output {
    VCAM_LOG(@"Session addOutput: output.class=%@", NSStringFromClass([output class]));
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

#pragma mark - 4. 诊断 AVCaptureVideoDataOutput 代理

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    VCAM_LOG(@"VideoDataOutput setSampleBufferDelegate: %@, queue=%p",
             NSStringFromClass([delegate class]), queue);
    %orig;
}

%end

#pragma mark - 5. 诊断 AVCaptureConnection 的方向/镜像设置

%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
    VCAM_LOG(@"Connection setVideoOrientation: %ld", (long)orientation);
    %orig;
}

- (void)setVideoMirrored:(BOOL)mirrored {
    VCAM_LOG(@"Connection setVideoMirrored: %d", mirrored);
    %orig;
}

%end

#pragma mark - 6. 诊断 AVCaptureDevice

%hook AVCaptureDevice

- (void)setActiveVideoMinFrameDuration:(CMTime)duration {
    VCAM_LOG(@"Device setActiveVideoMinFrameDuration: %f", CMTimeGetSeconds(duration));
    %orig;
}

%end

#pragma mark - 7. 诊断 CALayer 的 insertSublayer 系列方法

%hook CALayer

- (void)addSublayer:(CALayer *)layer {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"CALayer addSublayer on %@: new=%@", NSStringFromClass([self class]), NSStringFromClass([layer class]));
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)idx {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"CALayer insertSublayer:atIndex: on %@: new=%@ idx=%u",
                 NSStringFromClass([self class]), NSStringFromClass([layer class]), idx);
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"CALayer insertSublayer:above: on %@: new=%@ above=%@",
                 NSStringFromClass([self class]), NSStringFromClass([layer class]), NSStringFromClass([sibling class]));
    }
    %orig;
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"CALayer insertSublayer:below: on %@: new=%@ below=%@",
                 NSStringFromClass([self class]), NSStringFromClass([layer class]), NSStringFromClass([sibling class]));
    }
    %orig;
}

- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)newLayer {
    if ([NSStringFromClass([self class]) containsString:@"PreviewLayer"]) {
        VCAM_LOG(@"CALayer replaceSublayer:with: on %@: old=%@ new=%@",
                 NSStringFromClass([self class]), NSStringFromClass([oldLayer class]), NSStringFromClass([newLayer class]));
    }
    %orig;
}

%end

#pragma mark - 8. 进程信息

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    VCAM_LOG(@"========== VCAM Analyzer 已加载 ==========");
    VCAM_LOG(@"进程名: %@", processName);
    VCAM_LOG(@"Bundle ID: %@", [[NSBundle mainBundle] bundleIdentifier]);

    if ([processName containsString:@"Camera"] ||
        [processName containsString:@"camera"]) {
        VCAM_LOG(@"检测到系统相机进程，开始诊断");
    }
}