// 系统相机替换模式
// 系统相机的预览层不走 addSublayer:，而是通过 didMoveToSuperlayer 添加到视图层级，
// 所以需要单独 Hook 这个方法，把替换层插进去。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "VCAMSystemCamera.h"

%hook AVCaptureVideoPreviewLayer

- (void)didMoveToSuperlayer {
    %orig;
    VCAMSetupPreviewLayer(self);
}

%end