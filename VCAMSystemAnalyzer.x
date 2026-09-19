#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import "VCAMDebugLog.h"

%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    VCAM_LOG(@"layoutSublayers count=%lu", (unsigned long)self.sublayers.count);
    for (CALayer *sub in self.sublayers) {
        VCAM_LOG(@"  sub: %@ frame=%@", NSStringFromClass([sub class]), NSStringFromCGRect(sub.frame));
    }
}

%end

%ctor {
    VCAM_LOG_STARTUP();
}