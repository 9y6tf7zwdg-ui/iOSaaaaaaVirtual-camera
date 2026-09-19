#import "VCAMRangeSlider.h"

static const CGFloat kThumbRadius = 14.0;
static const CGFloat kTrackHeight = 4.0;
static const CGFloat kThumbTouchPadding = 20.0;

@interface VCAMRangeSlider ()
@property (nonatomic, assign) NSInteger activeThumb;
@end

@implementation VCAMRangeSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lowerValue = 0.0;
        _upperValue = 1.0;
        _activeThumb = -1;
        _trackColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        _highlightedTrackColor = [UIColor systemBlueColor];
        _thumbColor = [UIColor whiteColor];
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)setLowerValue:(CGFloat)lowerValue {
    if (lowerValue < 0) lowerValue = 0;
    if (lowerValue > _upperValue) lowerValue = _upperValue;
    _lowerValue = lowerValue;
    [self setNeedsDisplay];
}

- (void)setUpperValue:(CGFloat)upperValue {
    if (upperValue > 1) upperValue = 1;
    if (upperValue < _lowerValue) upperValue = _lowerValue;
    _upperValue = upperValue;
    [self setNeedsDisplay];
}

- (CGFloat)trackWidth {
    return self.bounds.size.width - kThumbRadius * 2;
}

- (CGFloat)xPositionForValue:(CGFloat)value {
    return kThumbRadius + value * [self trackWidth];
}

- (CGFloat)valueForXPosition:(CGFloat)x {
    CGFloat value = (x - kThumbRadius) / [self trackWidth];
    if (value < 0) value = 0;
    if (value > 1) value = 1;
    return value;
}

- (void)drawRect:(CGRect)rect {
    CGFloat midY = self.bounds.size.height / 2.0;

    CGRect trackRect = CGRectMake(kThumbRadius, midY - kTrackHeight/2.0, [self trackWidth], kTrackHeight);
    UIBezierPath *trackPath = [UIBezierPath bezierPathWithRoundedRect:trackRect cornerRadius:kTrackHeight/2.0];
    [self.trackColor setFill];
    [trackPath fill];

    CGFloat lowerX = [self xPositionForValue:self.lowerValue];
    CGFloat upperX = [self xPositionForValue:self.upperValue];
    CGRect highlightRect = CGRectMake(lowerX, midY - kTrackHeight/2.0, upperX - lowerX, kTrackHeight);
    UIBezierPath *highlightPath = [UIBezierPath bezierPathWithRoundedRect:highlightRect cornerRadius:kTrackHeight/2.0];
    [self.highlightedTrackColor setFill];
    [highlightPath fill];

    [self drawThumbAtX:lowerX midY:midY];
    [self drawThumbAtX:upperX midY:midY];
}

- (void)drawThumbAtX:(CGFloat)x midY:(CGFloat)midY {
    CGRect thumbRect = CGRectMake(x - kThumbRadius, midY - kThumbRadius, kThumbRadius * 2, kThumbRadius * 2);
    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithOvalInRect:CGRectOffset(thumbRect, 0, 1)];
    [[UIColor colorWithWhite:0 alpha:0.15] setFill];
    [shadowPath fill];

    UIBezierPath *thumbPath = [UIBezierPath bezierPathWithOvalInRect:thumbRect];
    [self.thumbColor setFill];
    [thumbPath fill];
    [[UIColor colorWithWhite:0.6 alpha:1.0] setStroke];
    thumbPath.lineWidth = 1.0;
    [thumbPath stroke];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    CGFloat lowerX = [self xPositionForValue:self.lowerValue];
    CGFloat upperX = [self xPositionForValue:self.upperValue];
    CGFloat distLower = fabs(point.x - lowerX);
    CGFloat distUpper = fabs(point.x - upperX);

    if (distLower < kThumbTouchPadding && distLower <= distUpper) {
        self.activeThumb = 0;
    } else if (distUpper < kThumbTouchPadding) {
        self.activeThumb = 1;
    } else {
        self.activeThumb = (distLower < distUpper) ? 0 : 1;
    }
    [self updateThumbWithPoint:point];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    [self updateThumbWithPoint:point];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.activeThumb = -1;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)updateThumbWithPoint:(CGPoint)point {
    CGFloat value = [self valueForXPosition:point.x];
    if (self.activeThumb == 0) {
        if (value > self.upperValue) value = self.upperValue;
        self.lowerValue = value;
    } else if (self.activeThumb == 1) {
        if (value < self.lowerValue) value = self.lowerValue;
        self.upperValue = value;
    }
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self setNeedsDisplay];
}

@end