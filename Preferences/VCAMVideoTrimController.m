#import "VCAMVideoTrimController.h"
#import "VCAMRangeSlider.h"

@interface VCAMVideoTrimController ()
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, weak) id<VCAMVideoTrimDelegate> delegate;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) VCAMRangeSlider *rangeSlider;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIView *thumbnailsContainer;
@property (nonatomic, strong) AVAssetImageGenerator *imageGenerator;
@end

@implementation VCAMVideoTrimController

- (instancetype)initWithAsset:(AVAsset *)asset delegate:(id<VCAMVideoTrimDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _asset = asset;
        _delegate = delegate;
        _duration = CMTimeGetSeconds(asset.duration);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"选择视频片段";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"应用"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(applyTapped)];

    [self setupUI];
    [self loadThumbnails];
}

- (void)setupUI {
    CGFloat padding = 16;
    CGFloat width = self.view.bounds.size.width - padding * 2;

    self.thumbnailsContainer = [[UIView alloc] initWithFrame:CGRectMake(padding, 100, width, 80)];
    self.thumbnailsContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.thumbnailsContainer.layer.cornerRadius = 8;
    self.thumbnailsContainer.clipsToBounds = YES;
    [self.view addSubview:self.thumbnailsContainer];

    self.rangeSlider = [[VCAMRangeSlider alloc] initWithFrame:CGRectMake(padding, 200, width, 60)];
    self.rangeSlider.lowerValue = 0.0;
    self.rangeSlider.upperValue = 1.0;
    [self.rangeSlider addTarget:self action:@selector(rangeChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.rangeSlider];

    self.timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, 270, width, 30)];
    self.timeLabel.textAlignment = NSTextAlignmentCenter;
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.timeLabel.textColor = [UIColor labelColor];
    [self.view addSubview:self.timeLabel];

    [self updateTimeLabel];
}

- (void)loadThumbnails {
    self.imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:self.asset];
    self.imageGenerator.appliesPreferredTrackTransform = YES;
    self.imageGenerator.maximumSize = CGSizeMake(160, 160);
    self.imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
    self.imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;

    CGFloat thumbCount = 8;
    CGFloat thumbWidth = self.thumbnailsContainer.bounds.size.width / thumbCount;
    CGFloat thumbHeight = self.thumbnailsContainer.bounds.size.height;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSInteger i = 0; i < thumbCount; i++) {
            NSTimeInterval t = self.duration * i / (thumbCount - 1);
            CMTime time = CMTimeMakeWithSeconds(t, 900);
            NSError *error = nil;
            CGImageRef cgImage = [self.imageGenerator copyCGImageAtTime:time actualTime:NULL error:&error];
            if (cgImage) {
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(i * thumbWidth, 0, thumbWidth, thumbHeight)];
                    iv.image = image;
                    iv.contentMode = UIViewContentModeScaleAspectFill;
                    iv.clipsToBounds = YES;
                    [self.thumbnailsContainer addSubview:iv];
                });
            }
        }
    });
}

- (void)rangeChanged {
    [self updateTimeLabel];
}

- (void)updateTimeLabel {
    NSTimeInterval start = self.rangeSlider.lowerValue * self.duration;
    NSTimeInterval end = self.rangeSlider.upperValue * self.duration;
    self.timeLabel.text = [NSString stringWithFormat:@"%.2f 秒  ~  %.2f 秒  (共 %.2f 秒)", start, end, end - start];
}

- (void)cancelTapped {
    [self.delegate videoTrimControllerDidCancel:self];
}

- (void)applyTapped {
    NSTimeInterval start = self.rangeSlider.lowerValue * self.duration;
    NSTimeInterval end = self.rangeSlider.upperValue * self.duration;

    if (end - start < 0.5) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"片段太短"
                                                                       message:@"请选择至少 0.5 秒的片段"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"处理中..."
                                                                     message:@"正在裁剪视频..."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_trimmed.mov"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:tempPath]) [fm removeItemAtPath:tempPath error:nil];

    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:self.asset presetName:AVAssetExportPresetPassthrough];
    exportSession.outputURL = [NSURL fileURLWithPath:tempPath];
    exportSession.outputFileType = AVFileTypeQuickTimeMovie;

    CMTime startTime = CMTimeMakeWithSeconds(start, 900);
    CMTime endTime = CMTimeMakeWithSeconds(end, 900);
    exportSession.timeRange = CMTimeRangeFromTimeToTime(startTime, endTime);

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                    [self.delegate videoTrimController:self didFinishWithURL:[NSURL fileURLWithPath:tempPath]];
                } else {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"裁剪失败"
                                                                                   message:exportSession.error.localizedDescription ?: @"未知错误"
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                }
            }];
        });
    }];
}

@end