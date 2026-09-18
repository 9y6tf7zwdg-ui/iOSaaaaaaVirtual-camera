#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// 声明 NSTask 私有类，替代被禁用的 system()
@interface NSTask : NSObject
@property (nonatomic, retain) NSString *launchPath;
@property (nonatomic, retain) NSArray *arguments;
- (void)launch;
- (void)waitUntilExit;
@end

@interface VCAMRootListController : PSListController
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
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];
    UIImageView *logoView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    logoView.center = CGPointMake(headerView.bounds.size.width / 2, 40);
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.image = [UIImage imageWithContentsOfFile:@"/Library/PreferenceBundles/VCAMPrefs.bundle/icon.png"];
    logoView.layer.cornerRadius = 10;
    logoView.clipsToBounds = YES;
    [headerView addSubview:logoView];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 70, headerView.bounds.size.width, 30)];
    titleLabel.text = @"VCAM - Virtual Camera";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [headerView addSubview:titleLabel];
    
    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 95, headerView.bounds.size.width, 20)];
    versionLabel.text = @"Version 1.0.0";
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.font = [UIFont systemFontOfSize:12];
    versionLabel.textColor = [UIColor grayColor];
    [headerView addSubview:versionLabel];
    
    self.table.tableHeaderView = headerView;
    
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStylePlain target:self action:@selector(applySettings)];
    self.navigationItem.rightBarButtonItem = applyButton;
}

- (void)applySettings {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, NULL, YES);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"设置已应用。建议重启 SpringBoard 生效。" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil];
    UIAlertAction *respring = [UIAlertAction actionWithTitle:@"重启 SpringBoard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/killall"];
        [task setArguments:@[@"-9", @"SpringBoard"]];
        [task launch];
    }];
    [alert addAction:okAction];
    [alert addAction:respring];
    [self presentViewController:alert animated:YES completion:nil];
}
@end