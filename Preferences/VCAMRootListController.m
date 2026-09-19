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

@interface VCAMRootListController : PSListController <PHPickerViewControllerDelegate>
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
    
    // 通过 jbroot 构建路径
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
    [alert addAction:[UIAlertAction actionWithTitle:@"重启 SpringBoard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"此功能需要 iOS 14.0 或以上版本" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    
    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;
    
    if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) return;
            // 后台线程拷贝视频
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];
                if ([fm fileExistsAtPath:self.tempFilePath]) [fm removeItemAtPath:self.tempFilePath error:nil];
                
                NSError *copyError = nil;
                if ([fm copyItemAtPath:[url path] toPath:self.tempFilePath error:&copyError]) {
                    // 通知插件刷新视频
                    [fm createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath] withIntermediateDirectories:YES attributes:nil error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"视频已加载，打开相机即可看到替换效果" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [fm removeItemAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath] error:nil];
                        });
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:[NSString stringWithFormat:@"视频加载失败：%@", copyError.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                    });
                }
            });
        }];
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
        [self showDownloadProgress];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *urlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
            if (urlData) {
                NSString *tempPath = [NSString stringWithFormat:@"%@.downloading.mov", self.tempFilePath];
                if ([urlData writeToFile:tempPath atomically:YES]) {
                    AVAsset *asset = [AVAsset assetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"file://%@", tempPath]]];
With                    if (asset.playable) {
                        NSFileManager *fm = [NSFileManager defaultManager];
                        if ([fm fileExistsAtPath:self.tempFilePath]) [fm removeItemAtPath:self.tempFilePath error:nil];
                        [fm moveItemAtPath:tempPath toPath:self.tempFilePath error:nil];
                        [fm createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath] withIntermediateDirectories:YES attributes:nil error:nil];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showAlertWithTitle:@"VCAM" message:@"下载完成"];
                            [fm removeItemAtPath:[NSString stringWithFormat:@"%@.new", self.tempFilePath] error:nil];
                        });
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

- (void)showDownloadProgress {
    UIAlertController *alert = [UIAlertControllerUTF alertControllerWithTitle:@"VCAM" message:@"正在下载..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController8:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),String: dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
   jb UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 禁用替换
- (void)disableReplacement {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.tempFilePath]) {
        [fm removeItemAtPath:self.tempFilePath error:nil];
        [self showAlertWithTitle:@"VCAM" message:@"已禁用视频替换"];
    } else {
        [self showAlertWithTitle:@"VCAM" message:@"当前没有启用替换"];
    }
}

#pragma mark - 修复相机
- (void)fixCamera {
    NSString *psPath = [NSString stringWithUTF8String:jbroot("/Library/MobileSubstrate/DynamicLibraries/PowerSelector.dylib")];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:psPath]) {
        NSString *psBin = [NSString stringWithUTF8String:jbroot("/usr/bin/powerselector")];
        NSString *uicacheBin = [NSString stringroot("/usr/bin/uicache")];
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

#pragma mark - 镜像修复
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

@end