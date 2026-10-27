#import "VLDisplayView.h"

#import <CoreGraphics/CoreGraphics.h>

@interface VLDisplayView ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL showingFrame;

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

@end
