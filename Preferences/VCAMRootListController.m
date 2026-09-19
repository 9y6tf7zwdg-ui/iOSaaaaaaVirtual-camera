#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#include <roothide.h>

@interface NSTask : NSObject
@property (nonatomic, retain) NSString *launchPath;
@property (nonatomic, retain) NSArray *arguments;
- (void)launch;
- (void)waitUntilExit;
@end

@interface VCAMRootListController : PSListController <PHPickerViewControllerDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UIVideoEditorControllerDelegate>
@property (nonatomic, strong) NSString *tempFilePath;
@property (nonatomic, strong) NSString *mirrorMarkPath;
@property (nonatomic, assign) BOOL downloadRunning;
@end

@implementation VCAMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"VCAM" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tempFilePath = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/temp.mov")];
    self.mirrorMarkPath = [NSString stringWithUTF8String:jbroot("/var/mobile/Library/Caches/vcam_is_mirrored_mark")];

    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 100)];
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 30, headerView.bounds.size.width, 30)];
    titleLabel.text = @"VCAM - Virtual Camera";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [headerView addSubview:titleLabel];

    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, headerView.bounds.size.width, 20)];
    versionLabel.text = @"Version 1.0.0 (RootHide)";
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.font = [UIFont systemFontOfSize:12];
    versionLabel.textColor = [UIColor grayColor];
    [headerView addSubview:versionLabel];

    self.table.tableHeaderView = headerView;

    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStylePlain target:self action:@selector(applySettings)];
    self.navigationItem.rightBarButtonItem = applyButton;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (void)applySettings {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.trizau.sileo.vcam.prefschanged"),
                                         NULL, NULL, YES);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"设置已应用。重启 SpringBoard 后生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启 SpringBoard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *killallPath = [NSString stringWithUTF8String:jbroot("/usr/bin/killall")];
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:killallPath];
        [task setArguments:@[@"-9", @"SpringBoard"]];
        [task launch];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 选择视频

- (void)selectVideo {
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter videosFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else {
        [self showAlertWithTitle:@"提示" message:@"此功能需要 iOS 14.0 或以上版本"];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;

    if (![provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [self showAlertWithTitle:@"VCAM" message:@"未找到有效的视频"];
        return;
    }

    [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (error || !url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"VCAM" message:@"视频加载失败"];
            });
            return;
        }

        BOOL accessing = [url startAccessingSecurityScopedResource];
        NSData *videoData = [NSData dataWithContentsOfURL:url];
        if (accessing) [url stopAccessingSecurityScopedResource];

        if (!videoData || videoData.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"VCAM" message:@"读取视频失败，请确认视频已下载到本地"];
            });
            return;
        }

        NSString *tempCopyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_import.mov"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:tempCopyPath]) [fm removeItemAtPath:tempCopyPath error:nil];

        NSError *writeError = nil;
        if (![videoData writeToFile:tempCopyPath options:NSDataWritingAtomic error:&writeError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"VCAM" message:@"写入临时文件失败"];
            });
            return;
        }

        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:tempCopyPath]];
        if (!asset.playable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"VCAM" message:@"视频格式不可播放"];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self openNativeEditorWithPath:tempCopyPath];
        });
    }];
}

#pragma mark - 原生视频剪辑界面

- (void)openNativeEditorWithPath:(NSString *)path {
    if (![UIVideoEditorController canEditVideoAtPath:path]) {
        [self finalizeVideoWithPath:path];
        return;
    }

    UIVideoEditorController *editor = [[UIVideoEditorController alloc] init];
    editor.videoPath = path;
    editor.videoMaximumDuration = 3600.0;
    editor.videoQuality = UIImagePickerControllerQualityTypeHigh;
    editor.delegate = self;
    editor.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:editor animated:YES completion:nil];
}

#pragma mark - UIVideoEditorControllerDelegate

- (void)videoEditorController:(UIVideoEditorController *)editor didSaveEditedVideoToPath:(NSString *)editedVideoPath {
    [editor dismissViewControllerAnimated:YES completion:^{
        NSLog(@"[VCAM] 用户保存了剪辑后的视频: %@", editedVideoPath);
        [self finalizeVideoWithPath:editedVideoPath];
    }];
}

- (void)videoEditorController:(UIVideoEditorController *)editor didFailWithError:(NSError *)error {
    [editor dismissViewControllerAnimated:YES completion:^{
        [self showAlertWithTitle:@"VCAM" message:[NSString stringWithFormat:@"剪辑失败：%@", error.localizedDescription ?: @"未知错误"]];
    }];
}

- (void)videoEditorControllerDidCancel:(UIVideoEditorController *)editor {
    [editor dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 保存视频（强制导出为横屏像素，与相机采集帧对齐）

- (void)finalizeVideoWithPath:(NSString *)sourcePath {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourcePath]];
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!videoTrack) {
            [self copyToTempPath:sourcePath];
            return;
        }

        CGSize naturalSize = videoTrack.naturalSize;
        CGAffineTransform preferredTransform = videoTrack.preferredTransform;

        // 1. 计算视频正确的显示尺寸
        CGSize displaySize = CGSizeApplyAffineTransform(naturalSize, preferredTransform);
        displaySize = CGSizeMake(fabs(displaySize.width), fabs(displaySize.height));

        // 2. 目标：强制导出为横屏像素（宽 > 高），与相机底层采集格式一致
        CGSize renderSize = displaySize;
        CGAffineTransform finalTransform = preferredTransform;

        if (displaySize.width < displaySize.height) {
            // 如果视频是竖屏像素，旋转 90 度导出为横屏
            renderSize = CGSizeMake(displaySize.height, displaySize.width);
            finalTransform = CGAffineTransformConcat(CGAffineTransformMakeRotation(M_PI_2),
                                                     CGAffineTransformMakeTranslation(renderSize.width, 0));
        }

        // 3. 构建 Video Composition
        AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
        videoComposition.renderSize = renderSize;
        videoComposition.frameDuration = CMTimeMake(1, 30);

        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

        AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
        [layerInstruction setTransform:finalTransform atTime:kCMTimeZero];

        instruction.layerInstructions = @[layerInstruction];
        videoComposition.instructions = @[instruction];

        // 4. 导出归一化后的视频
        NSString *exportPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_oriented.mov"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:exportPath]) [fm removeItemAtPath:exportPath error:nil];

        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
        exportSession.outputURL = [NSURL fileURLWithPath:exportPath];
        exportSession.outputFileType = AVFileTypeQuickTimeMovie;
        exportSession.videoComposition = videoComposition;
        exportSession.shouldOptimizeForNetworkUse = NO;

        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                [self copyToTempPath:exportPath];
            } else {
                NSLog(@"[VCAM] 方向校正导出失败: %@", exportSession.error);
                [self copyToTempPath:sourcePath];
            }
        }];
    });
}

- (void)copyToTempPath:(NSString *)sourcePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.tempFilePath]) {
        [fm removeItemAtPath:self.tempFilePath error:nil];
    }
    NSError *copyError = nil;
    if ([fm copyItemAtPath:sourcePath toPath:self.tempFilePath error:&copyError]) {
        [fm createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath]
            withIntermediateDirectories:YES attributes:nil error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:@"VCAM" message:@"视频已加载，打开相机即可看到替换效果"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [fm removeItemAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath] error:nil];
            });
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:@"VCAM" message:[NSString stringWithFormat:@"保存视频失败：%@", copyError.localizedDescription]];
        });
    }
}

#pragma mark - 下载视频

- (void)downloadVideo {
    if (self.downloadRunning) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载视频" message:@"输入远程视频地址（MOV/MP4）" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"http://...";
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *urlString = alert.textFields[0].text;
        if (urlString.length == 0) return;

        self.downloadRunning = YES;

        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"正在下载..." preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:progressAlert animated:YES completion:nil];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *urlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressAlert dismissViewControllerAnimated:YES completion:nil];
            });
            if (urlData) {
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_download.mov"];
                if ([urlData writeToFile:tempPath atomically:YES]) {
                    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:tempPath]];
                    if (asset.playable) {
                        [self finalizeVideoWithPath:tempPath];
                    } else {
                        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showAlertWithTitle:@"VCAM" message:@"视频格式无效，请使用 MOV 或 MP4"];
                        });
                    }
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showAlertWithTitle:@"VCAM" message:@"视频写入失败"];
                    });
                }
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showAlertWithTitle:@"VCAM" message:@"下载失败，请检查网络或地址"];
                });
            }
            self.downloadRunning = NO;
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 其他操作

- (void)disableReplacement {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.tempFilePath]) {
        [fm removeItemAtPath:self.tempFilePath error:nil];
        [self showAlertWithTitle:@"VCAM" message:@"已禁用视频替换"];
    } else {
        [self showAlertWithTitle:@"VCAM" message:@"当前没有启用替换"];
    }
}

- (void)fixCamera {
    NSString *psPath = [NSString stringWithUTF8String:jbroot("/Library/MobileSubstrate/DynamicLibraries/PowerSelector.dylib")];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:psPath]) {
        NSString *psBin = [NSString stringWithUTF8String:jbroot("/usr/bin/powerselector")];
        NSString *uicacheBin = [NSString stringWithUTF8String:jbroot("/usr/bin/uicache")];
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:psBin];
        [task setArguments:@[@"ldrestart"]];
        [task launch];
        [self showAlertWithTitle:@"VCAM" message:@"正在重启服务以修复相机..."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSTask *uiCacheTask = [[NSTask alloc] init];
            [uiCacheTask setLaunchPath:uicacheBin];
            [uiCacheTask launch];
        });
    } else {
        [self showAlertWithTitle:@"需要 PowerSelector" message:@"请从 Cydia 安装 PowerSelector 以修复相机"];
    }
}

- (void)toggleMirrorFix {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.mirrorMarkPath]) {
        [fm removeItemAtPath:self.mirrorMarkPath error:nil];
        [self showAlertWithTitle:@"VCAM" message:@"已关闭拍照镜像修复"];
    } else {
        [fm createDirectoryAtPath:self.mirrorMarkPath withIntermediateDirectories:YES attributes:nil error:nil];
        [self showAlertWithTitle:@"VCAM" message:@"已开启拍照镜像修复"];
    }
    [self reloadSpecifiers];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end