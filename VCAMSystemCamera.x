#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "VCAMDebugLog.h"

%ctor {
    VCAM_LOG_STARTUP();
}