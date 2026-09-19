#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#include <roothide.h>

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

- (void)applySettings {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.trizau.sileo.vcam.prefschanged"),
                                         NULL, NULL, YES);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"设置已应用，建议重启 SpringBoard 生效。" preferredStyle:UIAlertControllerStyleAlert];
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
@end