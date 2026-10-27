#import "VLDisplayView.h"

#import <CoreGraphics/CoreGraphics.h>

@interface VLDisplayView ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL showingFrame;
@property (nonatomic, assign) uint32_t frameWidth;
@property (nonatomic, assign) uint32_t frameHeight;

@end

@implementation VLDisplayView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		[self setup];
	}
	return self;
}

- (void)setup {
	self.backgroundColor = UIColor.blackColor;
	self.layer.cornerRadius = 12.0;
	self.layer.masksToBounds = YES;
	self.layer.contentsGravity = kCAGravityResizeAspect;
	self.layer.borderWidth = 1.0;
	self.layer.borderColor = UIColor.tertiaryLabelColor.CGColor;

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.textAlignment = NSTextAlignmentCenter;
	self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.statusLabel.textColor = UIColor.lightGrayColor;
	[self addSubview:self.statusLabel];

	[NSLayoutConstraint activateConstraints:@[
		[self.statusLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
		[self.statusLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		[self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16.0],
		[self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16.0],
	]];
}

- (void)setStatusText:(NSString *)statusText {
	_statusText = [statusText copy];
	self.statusLabel.text = statusText;
}

- (BOOL)hasFrame {
	return self.showingFrame;
}

- (void)updateWithWidth:(uint32_t)width height:(uint32_t)height frame:(NSData *)frame {
	if (width == 0 || height == 0 || frame.length < (NSUInteger)width * height * 4) {
		return;
	}

	CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)frame);
	if (provider == NULL) {
		return;
	}
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGImageRef image = CGImageCreate((size_t)width,
									 (size_t)height,
									 8,
									 32,
									 (size_t)width * 4,
									 colorSpace,
									 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
									 provider,
									 NULL,
									 false,
									 kCGRenderingIntentDefault);
	CGColorSpaceRelease(colorSpace);
	CGDataProviderRelease(provider);
	if (image == NULL) {
		return;
	}

	self.layer.contents = (__bridge id)image;
	CGImageRelease(image);

	self.frameWidth = width;
	self.frameHeight = height;

	if (!self.showingFrame) {
		self.showingFrame = YES;
		self.statusLabel.text = nil;
		self.layer.borderColor = UIColor.clearColor.CGColor;
	}
}

- (void)clearFrame {
	self.showingFrame = NO;
	self.layer.contents = nil;
	self.layer.borderColor = UIColor.tertiaryLabelColor.CGColor;
	self.statusLabel.text = self.statusText;
}

#pragma mark - 触摸

/// 画面按 kCAGravityResizeAspect 居中留黑边，这里算回真正的画面区域。
- (CGRect)imageRectInBounds {
	if (self.frameWidth == 0 || self.frameHeight == 0) {
		return CGRectZero;
	}
	CGFloat boundsWidth = CGRectGetWidth(self.bounds);
	CGFloat boundsHeight = CGRectGetHeight(self.bounds);
	if (boundsWidth <= 0 || boundsHeight <= 0) {
		return CGRectZero;
	}
	CGFloat scale = MIN(boundsWidth / (CGFloat)self.frameWidth, boundsHeight / (CGFloat)self.frameHeight);
	CGFloat width = (CGFloat)self.frameWidth * scale;
	CGFloat height = (CGFloat)self.frameHeight * scale;
	return CGRectMake((boundsWidth - width) / 2.0, (boundsHeight - height) / 2.0, width, height);
}

- (void)handleTouches:(NSSet<UITouch *> *)touches
				phase:(VLDisplayTouchPhase)phase
		 allowOutside:(BOOL)allowOutside {
	if (self.touchHandler == nil) {
		return;
	}
	UITouch *touch = touches.anyObject;
	CGRect rect = [self imageRectInBounds];
	if (touch == nil || CGRectIsEmpty(rect)) {
		return;
	}

	CGPoint point = [touch locationInView:self];
	if (!allowOutside && !CGRectContainsPoint(rect, point)) {
		return;
	}

	CGFloat x = (point.x - CGRectGetMinX(rect)) / CGRectGetWidth(rect);
	CGFloat y = (point.y - CGRectGetMinY(rect)) / CGRectGetHeight(rect);
	x = MIN(MAX(x, 0.0), 1.0);
	y = MIN(MAX(y, 0.0), 1.0);
	self.touchHandler(phase, x, y);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	[self handleTouches:touches phase:VLDisplayTouchPhaseBegan allowOutside:NO];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	[self handleTouches:touches phase:VLDisplayTouchPhaseMoved allowOutside:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	[self handleTouches:touches phase:VLDisplayTouchPhaseEnded allowOutside:YES];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	[self handleTouches:touches phase:VLDisplayTouchPhaseEnded allowOutside:YES];
}

@end
