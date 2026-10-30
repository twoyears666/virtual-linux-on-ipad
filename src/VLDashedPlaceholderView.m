// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLDashedPlaceholderView.h"

@interface VLDashedPlaceholderView ()

@property (nonatomic, strong) CAShapeLayer *borderLayer;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIButton *playButton;

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

	// 中间的圆形启动按钮：整个占位区也可点，按钮是第一视觉入口。
	self.playButton = [UIButton buttonWithType:UIButtonTypeCustom];
	self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
	self.playButton.backgroundColor = UIColor.systemBlueColor;
	self.playButton.layer.cornerRadius = 32.0;
	self.playButton.tintColor = UIColor.whiteColor;
	UIImageSymbolConfiguration *symbol =
		[UIImageSymbolConfiguration configurationWithPointSize:28.0 weight:UIImageSymbolWeightSemibold];
	[self.playButton setImage:[UIImage systemImageNamed:@"play.fill" withConfiguration:symbol]
					 forState:UIControlStateNormal];
	[self.playButton addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:self.playButton];

	[NSLayoutConstraint activateConstraints:@[
		[self.textLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
		[self.textLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-44.0],
		[self.textLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16.0],
		[self.textLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16.0],

		[self.playButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
		[self.playButton.topAnchor constraintEqualToAnchor:self.textLabel.bottomAnchor constant:16.0],
		[self.playButton.widthAnchor constraintEqualToConstant:64.0],
		[self.playButton.heightAnchor constraintEqualToConstant:64.0],
	]];

	UITapGestureRecognizer *tap =
		[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
	[self addGestureRecognizer:tap];
	self.userInteractionEnabled = YES;

	[self updateColors];
}

- (void)handleTap {
	if (self.onTap) {
		self.onTap();
	}
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
