#ifndef VCAMDebugLog_h
#define VCAMDebugLog_h

#import <Foundation/Foundation.h>
#include <stdarg.h>

static inline NSString *VCAMDebugLogPath(void) {
    return @"/var/mobile/VCAM_debug.log";
}

static inline void VCAMDebugLogWrite(NSString *line) {
    static NSLock *lock = nil;
    if (!lock) lock = [[NSLock alloc] init];
    [lock lock];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VCAMDebugLogPath()]) {
            [line writeToFile:VCAMDebugLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VCAMDebugLogPath()];
            if (fh) {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                } @catch (NSException *e) {}
                [fh closeFile];
            }
        }
    } @catch (NSException *e) {}
    [lock unlock];
}

static inline void VCAMDebugLogInternal(const char *file, int line, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *timestamp = [df stringFromDate:[NSDate date]];
    NSString *fileName = [[NSString stringWithUTF8String:file] lastPathComponent];

    NSString *lineStr = [NSString stringWithFormat:@"[%@][%@][%@:%d] %@\n",
                         timestamp, [[NSProcessInfo processInfo] processName], fileName, line, msg];

    NSLog(@"[VCAM-Debug] %@", msg);
    VCAMDebugLogWrite(lineStr);
}

static inline void VCAMDebugLogClear(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:VCAMDebugLogPath()]) {
        [fm removeItemAtPath:VCAMDebugLogPath() error:nil];
    }
}

static inline NSString *VCAMDebugLogRead(void) {
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:VCAMDebugLogPath() encoding:NSUTF8StringEncoding error:&err];
    if (err || !content || content.length == 0) {
        return @"（暂无日志）\n\n请打开目标 App 后再回来查看。";
    }
    return content;
}

#define VCAM_LOG(fmt, ...) VCAMDebugLogInternal(__FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define VCAM_LOG_STARTUP() VCAMDebugLogInternal(__FILE__, __LINE__, @"========= 已加载 =========")

#endif