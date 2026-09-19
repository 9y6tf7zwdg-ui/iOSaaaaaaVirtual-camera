#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "VCAMDebugLog.h"
#import "VCAMSystemCamera.h"

%hook AVCaptureVideoPreviewLayer

- (void)didMoveToSuperlayer {
    %orig;
    VCAM_LOG(@"didMoveToSuperlayer 触发: superlayer=%@", NSStringFromClass([self.superlayer class]));
    VCAMSetupPreviewLayer(self);
}

%end

%ctor {
    VCAM_LOG_STARTUP();
}