#import <UIKit/UIKit.h>

@interface VCAMRangeSlider : UIControl

@property (nonatomic, assign) CGFloat lowerValue;
@property (nonatomic, assign) CGFloat upperValue;
@property (nonatomic, strong) UIColor *trackColor;
@property (nonatomic, strong) UIColor *highlightedTrackColor;
@property (nonatomic, strong) UIColor *thumbColor;

@end