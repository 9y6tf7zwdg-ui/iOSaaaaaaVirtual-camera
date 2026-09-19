#import "VCAMDebugLogController.h"
#import <UIKit/UIKit.h>
#import "../VCAMDebugLog.h"

@interface VCAMDebugLogController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation VCAMDebugLogController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"调试日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(refreshLog)],
    ];

    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.text = VCAMDebugLogRead();
    [self.view addSubview:self.textView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLog];
}

- (void)refreshLog {
    self.textView.text = VCAMDebugLogRead();
}

- (void)clearLog {
    VCAMDebugLogClear();
    self.textView.text = @"（已清空）";
}

@end