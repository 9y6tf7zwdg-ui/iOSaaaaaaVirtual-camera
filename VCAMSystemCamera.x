// 系统相机的 Hook 已合并到 Tweak.x 中，
// 本文件只保留启动日志，方便调试。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "VCAMDebugLog.h"

%ctor {
    VCAM_LOG_STARTUP();
}