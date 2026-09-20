#import "VCAMVideoRotateController.h"

@interface VCAMVideoRotateController ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, weak) id<VCAMVideoRotateDelegate> delegate;
@property (nonatomic, strong) NSString *videoPath;
@property (nonatomic, assign) NSInteger rotationCount; // 0=0°,1=90°,2=180°,3=270°
@property (nonatomic, strong) UILabel *infoLabel;
@end

@implementation VCAMVideoRotateController

- (instancetype)initWithVideoPath:(NSString *)path delegate:(id<VCAMVideoRotateDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoPath = path;
        _delegate = delegate;
        _rotationCount = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"旋转视频";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    // 播放器预览
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.videoPath]];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:self.playerLayer];
    [self.player play];

    // 底部工具栏
    CGFloat toolbarHeight = 100;
    UIView *toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - toolbarHeight, self.view.bounds.size.width, toolbarHeight)];
    toolbar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    [self.view addSubview:toolbar];

    // 旋转按钮
    UIButton *rotateBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    rotateBtn.frame = CGRectMake(0, 10, toolbar.bounds.size.width, 44);
    [rotateBtn setTitle:@"↻ 顺时针旋转 90°" forState:UIControlStateNormal];
    [rotateBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    rotateBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [rotateBtn addTarget:self action:@selector(rotateTapped) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:rotateBtn];

    // 角度提示
    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, toolbar.bounds.size.width, 30)];
    self.infoLabel.textAlignment = NSTextAlignmentCenter;
    self.infoLabel.textColor = [UIColor lightGrayColor];
    self.infoLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    [self updateInfoLabel];
    [toolbar addSubview:self.infoLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.playerLayer.frame = self.view.bounds;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)playbackEnded:(NSNotification *)note {
    [self.player seekToTime:kCMTimeZero];
    [self.player play];
}

- (void)rotateTapped {
    self.rotationCount = (self.rotationCount + 1) % 4;
    [self updateInfoLabel];
    // 预览 layer 旋转（视觉反馈）
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.25];
    CGFloat angle = self.rotationCount * M_PI_2;
    self.playerLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    [CATransaction commit];
}

- (void)updateInfoLabel {
    self.infoLabel.text = [NSString stringWithFormat:@"当前角度：%ld°", (long)(self.rotationCount * 90)];
}

- (void)cancel {
    [self.player pause];
    [self.delegate videoRotateControllerDidCancel:self];
}

- (void)done {
    [self.player pause];

    if (self.rotationCount == 0) {
        // 不旋转，直接返回原文件
        [self.delegate videoRotateController:self didFinishWithPath:self.videoPath];
        return;
    }

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"正在导出旋转后的视频" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self exportRotatedVideoWithCompletion:^(NSString *outputPath, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:^{
                    if (outputPath && !error) {
                        [self.delegate videoRotateController:self didFinishWithPath:outputPath];
                    } else {
                        UIAlertController *err = [UIAlertController alertControllerWithTitle:@"导出失败" message:error.localizedDescription ?: @"未知错误" preferredStyle:UIAlertControllerStyleAlert];
                        [err addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:err animated:YES completion:nil];
                    }
                }];
            });
        }];
    });
}

- (void)exportRotatedVideoWithCompletion:(void (^)(NSString *, NSError *))completion {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.videoPath]];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) {
        completion(nil, [NSError errorWithDomain:@"VCAM" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"视频没有视频轨"}]);
        return;
    }

    CGSize naturalSize = videoTrack.naturalSize;
    CGAffineTransform preferredTransform = videoTrack.preferredTransform;

    // 把 preferredTransform 和用户旋转合并
    CGFloat userAngle = self.rotationCount * M_PI_2;
    CGAffineTransform userTransform = CGAffineTransformMakeRotation(userAngle);

    // 最终变换 = 用户旋转 × preferredTransform
    CGAffineTransform finalTransform = CGAffineTransformConcat(preferredTransform, userTransform);

    // 计算最终显示尺寸（应用 finalTransform 后的外包矩形）
    CGSize displaySize = CGSizeApplyAffineTransform(naturalSize, finalTransform);
    displaySize = CGSizeMake(fabs(displaySize.width), fabs(displaySize.height));

    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.renderSize = displaySize;
    videoComposition.frameDuration = CMTimeMake(1, 30);

    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

    AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:finalTransform atTime:kCMTimeZero];

    instruction.layerInstructions = @[layerInstruction];
    videoComposition.instructions = @[instruction];

    NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_rotated.mov"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeQuickTimeMovie;
    session.videoComposition = videoComposition;
    session.shouldOptimizeForNetworkUse = NO;

    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status == AVAssetExportSessionStatusCompleted) {
            completion(outputPath, nil);
        } else {
            completion(nil, session.error ?: [NSError errorWithDomain:@"VCAM" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"导出失败"}]);
        }
    }];
}

@end