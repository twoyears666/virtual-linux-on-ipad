#import "VLFullScreenViewController.h"

#import "VLLinuxVirtualMachine.h"

@interface VLFullScreenViewController ()

@property (nonatomic, strong) VLLinuxVirtualMachine *machine;
@property (nonatomic, strong) VLDisplayView *displayView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *exitButton;
@property (nonatomic, strong) UIButton *keyboardButton;

@end

@implementation VLFullScreenViewController

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine {
	self = [super initWithNibName:nil bundle:nil];
	if (self) {
		_machine = machine;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	// 用 OverFullScreen 而不是 FullScreen：详情页的视图不会被移出窗口，
	// 那边那个隐形的输入框才还能成为第一响应者，键盘按钮才有用。
	self.modalPresentationStyle = UIModalPresentationOverFullScreen;

	[self buildDisplay];
	[self buildStatusLabel];
	[self buildExitButton];
	[self buildKeyboardButton];
}

/// 画面：4:3 恒定，按「适应」缩放到容器里，剩下的地方自然成为黑边。
- (void)buildDisplay {
	VLDisplayView *display = [[VLDisplayView alloc] init];
	display.translatesAutoresizingMaskIntoConstraints = NO;
	// 全屏下画面铺满可用空间，多余的边由 aspect ratio 决定，不裁切、不拉伸。
	display.layer.cornerRadius = 0.0;
	display.layer.borderWidth = 0.0;
	self.displayView = display;
	[self.view addSubview:display];

	__weak typeof(self) weakSelf = self;
	display.touchHandler = ^(VLDisplayTouchPhase phase, CGFloat x, CGFloat y) {
		typeof(self) strongSelf = weakSelf;
		VLLinuxVirtualMachine *machine = strongSelf.machine;
		if (machine == nil) {
			return;
		}
		switch (phase) {
			case VLDisplayTouchPhaseBegan:
				[machine sendTouchBeganAtNormalizedX:x y:y];
				break;
			case VLDisplayTouchPhaseMoved:
				[machine sendTouchMovedToNormalizedX:x y:y];
				break;
			case VLDisplayTouchPhaseEnded:
				[machine sendTouchEnded];
				break;
		}
	};

	// 4:3 优先：宽高比恒定，且整体不超出安全区。
	NSLayoutConstraint *ratio =
		[display.widthAnchor constraintEqualToAnchor:display.heightAnchor multiplier:4.0 / 3.0];
	ratio.priority = UILayoutPriorityRequired;
	NSLayoutConstraint *fitWidth =
		[display.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor];
	fitWidth.priority = UILayoutPriorityDefaultHigh;
	NSLayoutConstraint *fitHeight =
		[display.heightAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor];
	fitHeight.priority = UILayoutPriorityDefaultHigh;

	[NSLayoutConstraint activateConstraints:@[
		[display.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[display.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
		[display.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor],
		[display.heightAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor],
		ratio, fitWidth, fitHeight,
	]];
}

- (void)buildStatusLabel {
	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textColor = UIColor.lightGrayColor;
	label.text = @"正在启动…";
	self.statusLabel = label;
	[self.view addSubview:label];

	[NSLayoutConstraint activateConstraints:@[
		[label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
		[label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24.0],
		[label.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24.0],
	]];
}

- (void)buildExitButton {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	[button setTitle:@"退出全屏" forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.7];
	button.layer.cornerRadius = 8.0;
	[button addTarget:self action:@selector(exitTapped) forControlEvents:UIControlEventTouchUpInside];
	self.exitButton = button;
	[self.view addSubview:button];

	[NSLayoutConstraint activateConstraints:@[
		[button.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
		[button.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
		[button.widthAnchor constraintEqualToConstant:88.0],
		[button.heightAnchor constraintEqualToConstant:34.0],
	]];
}

- (void)buildKeyboardButton {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	[button setTitle:@"键盘" forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	[button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
	button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
	button.layer.cornerRadius = 8.0;
	[button addTarget:self action:@selector(keyboardTapped) forControlEvents:UIControlEventTouchUpInside];
	self.keyboardButton = button;
	[self.view addSubview:button];

	[NSLayoutConstraint activateConstraints:@[
		[button.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
		[button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
		[button.widthAnchor constraintEqualToConstant:64.0],
		[button.heightAnchor constraintEqualToConstant:32.0],
	]];
}

#pragma mark - 外部更新

- (void)updateStatus:(NSString *)status {
	if (self.displayView.hasFrame) {
		return;
	}
	self.statusLabel.text = status.length > 0 ? status : @"正在启动…";
}

- (void)updateFrameWidth:(uint32_t)width height:(uint32_t)height data:(NSData *)data {
	[self.displayView updateWithWidth:width height:height frame:data];
	self.statusLabel.text = nil;
}

- (void)clearFrame {
	[self.displayView clearFrame];
}

#pragma mark - 动作

- (void)exitTapped {
	if (self.dismissHandler != nil) {
		self.dismissHandler();
	}
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)keyboardTapped {
	if (self.keyboardRequestHandler != nil) {
		self.keyboardRequestHandler();
	}
}

@end
