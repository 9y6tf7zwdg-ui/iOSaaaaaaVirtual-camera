#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@protocol VCAMVideoTrimDelegate <NSObject>
- (void)videoTrimController:(UIViewController *)controller didFinishWithURL:(NSURL *)trimmedURL;
- (void)videoTrimControllerDidCancel:(UIViewController *)controller;
@end

@interface VCAMVideoTrimController : UIViewController

- (instancetype)initWithAsset:(AVAsset *)asset delegate:(id<VCAMVideoTrimDelegate>)delegate;

@end