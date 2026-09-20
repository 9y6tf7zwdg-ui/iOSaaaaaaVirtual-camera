#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@protocol VCAMVideoRotateDelegate <NSObject>
- (void)videoRotateController:(UIViewController *)controller didFinishWithPath:(NSString *)path;
- (void)videoRotateControllerDidCancel:(UIViewController *)controller;
@end

@interface VCAMVideoRotateController : UIViewController
- (instancetype)initWithVideoPath:(NSString *)path delegate:(id<VCAMVideoRotateDelegate>)delegate;
@end