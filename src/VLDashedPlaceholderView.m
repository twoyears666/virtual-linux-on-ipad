#import "VLDashedPlaceholderView.h"

@interface VLDashedPlaceholderView ()

@property (nonatomic, strong) CAShapeLayer *borderLayer;
@property (nonatomic, strong) UILabel *textLabel;

@end

@implementation VLDashedPlaceholderView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		[self setupLayers];
	}
	return self;
}

- (void)setupLayers {
	self.backgroundColor = UIColor.clearColor;
	self.layer.cornerRadius = 12.0;

	self.borderLayer = [CAShapeLayer layer];
	self.borderLayer.fillColor = UIColor.clearColor.CGColor;
	self.borderLayer.lineWidth = 1.5;
	self.borderLayer.lineDashPattern = @[ @6, @4 ];
	self.borderLayer.cornerRadius = 12.0;
	[self.layer addSublayer:self.borderLayer];

	self.textLabel = [[UILabel alloc] init];
	self.textLabel.translatesAutoresizingMaskIntoConstraints = NO;
	self.textLabel.numberOfLines = 0;
	self.textLabel.textAlignment = NSTextAlignmentCenter;
	self.textLabel.font = [UIFont systemFontOfSize:13.0];
	self.textLabel.textColor = UIColor.secondaryLabelColor;
	[self addSubview:self.textLabel];

	[NSLayoutConstraint activateConstraints:@[
		[self.textLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
		[self.textLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
		[self.textLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16.0],
		[self.textLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16.0],
	]];

	[self updateColors];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.borderLayer.frame = self.bounds;
	self.borderLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:12.0].CGPath;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
	[super traitCollectionDidChange:previousTraitCollection];
	[self updateColors];
}

- (void)updateColors {
	self.borderLayer.strokeColor = UIColor.tertiaryLabelColor.CGColor;
}

- (void)setText:(NSString *)text {
	_text = [text copy];
	self.textLabel.text = text;
}

@end
