// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLControlBar.h"

static const CGFloat VLControlBarButtonSize = 44.0;
static const CGFloat VLControlBarInset = 12.0;

@implementation VLControlBar {
	UIButton *_menuButton;
	UIButton *_keyboardButton;
	UIView *_divider;
	NSLayoutConstraint *_widthConstraint;
	NSLayoutConstraint *_firstConstraint;
	NSLayoutConstraint *_secondConstraint;
	/// 键盘按钮回调与键盘按钮可见性都要记住，等挂到父视图再落到约束上。
	void (^_keyboardHandler)(void);
}

- (instancetype)initWithKeyboardHandler:(void (^)(void))keyboardHandler {
	self = [super initWithFrame:CGRectZero];
	if (self) {
		_keyboardHandler = [keyboardHandler copy];
		_barOpacity = 1.0;
		_corner = VLControlBarCornerTopRight;
		_keyboardButtonVisible = YES;
		self.translatesAutoresizingMaskIntoConstraints = NO;
		self.clipsToBounds = YES;
		self.layer.cornerRadius = VLControlBarButtonSize / 2.0;
		[self buildSubviews];
		[self applyVisibilityAnimated:NO];
	}
	return self;
}

- (void)buildSubviews {
	// 半透明毛玻璃底，压在画面上不抢眼。
	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
		[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
	blur.translatesAutoresizingMaskIntoConstraints = NO;
	blur.userInteractionEnabled = NO;
	[self addSubview:blur];
	[NSLayoutConstraint activateConstraints:@[
		[blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[blur.topAnchor constraintEqualToAnchor:self.topAnchor],
		[blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
	]];

	_menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_menuButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self applySymbol:@"ellipsis" fallback:@"•••" toButton:_menuButton];
	_menuButton.tintColor = UIColor.whiteColor;
	_menuButton.showsMenuAsPrimaryAction = YES;
	[self addSubview:_menuButton];

	_keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_keyboardButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self applySymbol:@"keyboard" fallback:@"⌨" toButton:_keyboardButton];
	_keyboardButton.tintColor = UIColor.whiteColor;
	[_keyboardButton addTarget:self action:@selector(keyboardTapped)
			  forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:_keyboardButton];

	_divider = [[UIView alloc] init];
	_divider.translatesAutoresizingMaskIntoConstraints = NO;
	_divider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
	[self addSubview:_divider];

	_widthConstraint = [self.widthAnchor constraintEqualToConstant:VLControlBarButtonSize];
	[NSLayoutConstraint activateConstraints:@[
		[self.heightAnchor constraintEqualToConstant:VLControlBarButtonSize],
		_widthConstraint,
		[_menuButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
		[_menuButton.topAnchor constraintEqualToAnchor:self.topAnchor],
		[_menuButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_menuButton.widthAnchor constraintEqualToConstant:VLControlBarButtonSize],
		[_keyboardButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
		[_keyboardButton.topAnchor constraintEqualToAnchor:self.topAnchor],
		[_keyboardButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
		[_keyboardButton.widthAnchor constraintEqualToConstant:VLControlBarButtonSize],
		[_divider.trailingAnchor constraintEqualToAnchor:_keyboardButton.leadingAnchor],
		[_divider.topAnchor constraintEqualToAnchor:self.topAnchor constant:10.0],
		[_divider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10.0],
		[_divider.widthAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
	]];
}

- (void)applySymbol:(NSString *)symbol fallback:(NSString *)fallback toButton:(UIButton *)button {
	UIImage *image = [UIImage systemImageNamed:symbol];
	if (image != nil) {
		[button setImage:image forState:UIControlStateNormal];
		[button setPreferredSymbolConfiguration:
			[UIImageSymbolConfiguration configurationWithPointSize:17.0
														   weight:UIImageSymbolWeightSemibold]
							  forImageInState:UIControlStateNormal];
	} else {
		[button setTitle:fallback forState:UIControlStateNormal];
	}
}

#pragma mark - 外观

- (void)setBarOpacity:(CGFloat)barOpacity {
	_barOpacity = MAX(0.2, MIN(1.0, barOpacity));
	self.alpha = _barOpacity;
}

- (void)setKeyboardButtonVisible:(BOOL)visible {
	if (_keyboardButtonVisible == visible) {
		return;
	}
	_keyboardButtonVisible = visible;
	[self applyVisibilityAnimated:YES];
}

- (void)applyVisibilityAnimated:(BOOL)animated {
	// 没有键盘按钮时收成一个正圆，两个都在时是 44+44 的胶囊。
	_widthConstraint.constant = self.keyboardButtonVisible
		? VLControlBarButtonSize * 2.0
		: VLControlBarButtonSize;
	_keyboardButton.hidden = !self.keyboardButtonVisible;
	_divider.hidden = !self.keyboardButtonVisible;
	if (animated) {
		[UIView animateWithDuration:0.2 animations:^{
			[self.superview layoutIfNeeded];
		}];
	}
}

- (void)keyboardTapped {
	if (_keyboardHandler != nil) {
		_keyboardHandler();
	}
}

#pragma mark - 定位

- (void)setCorner:(VLControlBarCorner)corner {
	_corner = corner;
	[self installCornerConstraints];
}

- (void)setMenu:(UIMenu *)menu {
	_menu = [menu copy];
	_menuButton.menu = menu;
}

- (void)didMoveToSuperview {
	[super didMoveToSuperview];
	[self installCornerConstraints];
}

- (void)installCornerConstraints {
	UIView *superview = self.superview;
	if (superview == nil) {
		return;
	}
	if (_firstConstraint != nil) {
		[_firstConstraint setActive:NO];
		[_secondConstraint setActive:NO];
		_firstConstraint = nil;
		_secondConstraint = nil;
	}
	UILayoutGuide *safe = superview.safeAreaLayoutGuide;
	BOOL right = (self.corner == VLControlBarCornerTopRight ||
				  self.corner == VLControlBarCornerBottomRight);
	BOOL bottom = (self.corner == VLControlBarCornerBottomLeft ||
				   self.corner == VLControlBarCornerBottomRight);
	if (right) {
		_firstConstraint = [self.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
															   constant:-VLControlBarInset];
	} else {
		_firstConstraint = [self.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
															  constant:VLControlBarInset];
	}
	if (bottom) {
		// 再让出底部按键栏的位置，别和它叠在一起。
		_secondConstraint = [self.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
															  constant:-(VLControlBarInset + 48.0)];
	} else {
		_secondConstraint = [self.topAnchor constraintEqualToAnchor:safe.topAnchor
														   constant:VLControlBarInset];
	}
	_firstConstraint.active = YES;
	_secondConstraint.active = YES;
}

@end
