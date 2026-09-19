#ifndef VCAMSystemCamera_h
#define VCAMSystemCamera_h

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// 供 Tweak.x 调用：把替换层安装到 AVCaptureVideoPreviewLayer 上
void VCAMSetupPreviewLayer(AVCaptureVideoPreviewLayer *layer);

#endif