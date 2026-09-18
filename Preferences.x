#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface VCAMPrefsListController : PSListController
@end

@implementation VCAMPrefsListController
- (id)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"VCAM" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStylePlain target:self action:@selector(applySettings)];
    self.navigationItem.rightBarButtonItem = applyButton;
}

- (void)applySettings {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.trizau.sileo.vcam.prefschanged"), NULL, NULL, YES);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM" message:@"设置已应用，建议重启 SpringBoard 生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启 SpringBoard" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { system("killall -9 SpringBoard"); }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end