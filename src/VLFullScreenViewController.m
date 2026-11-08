// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLFullScreenViewController.h"

#import "VLKeyboardInput.h"
#import "VLLinuxVirtualMachine.h"
#import "VLTerminalEmulator.h"
#import "VLTerminalView.h"

@interface VLFullScreenViewController ()

@property (nonatomic, strong) VLLinuxVirtualMachine *machine;
@property (nonatomic, strong) VLKeyboardInput *keyboardInput;
@property (nonatomic, strong) VLDisplayView *displayView;
/// 客户机串口控制台：80x25 字符网格，安装器和 shell 的界面都画在这里。
@property (nonatomic, strong) VLTerminalView *terminalView;

@property (nonatomic, strong) UIView *statusHUD;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
/// 页面还没加载完就收到状态时先存下来，viewDidLoad 再补上。
@property (nonatomic, copy) NSString *pendingStatus;
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
	// 真正的独立整屏页面：不是叠在详情页上的浮层。键盘输入框由本页自己持有，
	// 不需要详情页留在窗口里，所以可以放心用 FullScreen。
	self.modalPresentationStyle = UIModalPresentationFullScreen;

	self.keyboardInput = [[VLKeyboardInput alloc] initWithMachine:self.machine];
	[self.keyboardInput attachToView:self.view];

	[self buildDisplay];
	[self buildTerminal];
	[self buildStatusHUD];
	[self buildExitButton];
	[self buildKeyboardButton];

	if (self.pendingStatus.length > 0) {
		self.statusLabel.text = self.pendingStatus;
	}
}

- (BOOL)prefersStatusBarHidden {
	return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
	return YES;
}

/// 客户机画面：整屏里放一块恒定的 4:3 区域并居中，多出来的部分留纯黑边。
/// 台前调度把窗口拉成别的比例时，画面也不能跟着变形或被裁掉。
- (void)buildDisplay {
	UIView *stage = [[UIView alloc] init];
	stage.translatesAutoresizingMaskIntoConstraints = NO;
	stage.backgroundColor = UIColor.blackColor;
	[self.view addSubview:stage];

	NSLayoutConstraint *preferredWidth =
		[stage.widthAnchor constraintEqualToAnchor:self.view.widthAnchor];
	// 宽度先贴着整屏；窄高（竖屏）时由高度上限反过来压宽度，始终维持 4:3。
	preferredWidth.priority = UILayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		[stage.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[stage.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
		preferredWidth,
		[stage.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor],
		[stage.heightAnchor constraintEqualToAnchor:stage.widthAnchor multiplier:0.75],
		[stage.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor],
	]];

	VLDisplayView *display = [[VLDisplayView alloc] init];
	display.translatesAutoresizingMaskIntoConstraints = NO;
	display.layer.cornerRadius = 0.0;
	display.layer.borderWidth = 0.0;
	self.displayView = display;
	[stage addSubview:display];

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

	[NSLayoutConstraint activateConstraints:@[
		[display.topAnchor constraintEqualToAnchor:stage.topAnchor],
		[display.leadingAnchor constraintEqualToAnchor:stage.leadingAnchor],
		[display.trailingAnchor constraintEqualToAnchor:stage.trailingAnchor],
		[display.bottomAnchor constraintEqualToAnchor:stage.bottomAnchor],
	]];
}

/// 没有 GPU 画面时这一页显示客户机串口控制台。
/// 安装器（d-i）的界面就是 80x25 的 ANSI 画面，必须按字符网格渲染；
/// 当成普通文本贴在 UITextView 里只会看到一堆转义序列。
- (void)buildTerminal {
	VLTerminalView *terminal = [[VLTerminalView alloc] init];
	terminal.translatesAutoresizingMaskIntoConstraints = NO;
	terminal.emulator = self.machine.terminal;
	self.terminalView = terminal;
	[self.view addSubview:terminal];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[terminal.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24.0],
		[terminal.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
		[terminal.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
		[terminal.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-56.0],
	]];
}

/// 左上角的启动状态：转圈 + 一行说明，画面上来就收起。
- (void)buildStatusHUD {
	UIView *hud = [[UIView alloc] init];
	hud.translatesAutoresizingMaskIntoConstraints = NO;
	hud.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
	hud.layer.cornerRadius = 10.0;
	hud.userInteractionEnabled = NO;
	self.statusHUD = hud;
	[self.view addSubview:hud];

	UIActivityIndicatorView *spinner =
		[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
	spinner.translatesAutoresizingMaskIntoConstraints = NO;
	spinner.color = UIColor.whiteColor;
	[spinner startAnimating];
	self.spinner = spinner;

	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textColor = UIColor.whiteColor;
	label.text = @"正在启动…";
	self.statusLabel = label;

	[hud addSubview:spinner];
	[hud addSubview:label];

	[NSLayoutConstraint activateConstraints:@[
		[hud.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12.0],
		[hud.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
		[spinner.leadingAnchor constraintEqualToAnchor:hud.leadingAnchor constant:10.0],
		[spinner.centerYAnchor constraintEqualToAnchor:hud.centerYAnchor],
		[label.leadingAnchor constraintEqualToAnchor:spinner.trailingAnchor constant:8.0],
		[label.trailingAnchor constraintEqualToAnchor:hud.trailingAnchor constant:-12.0],
		[label.topAnchor constraintEqualToAnchor:hud.topAnchor constant:6.0],
		[label.bottomAnchor constraintEqualToAnchor:hud.bottomAnchor constant:-6.0],
		[spinner.topAnchor constraintGreaterThanOrEqualToAnchor:hud.topAnchor constant:6.0],
		[spinner.bottomAnchor constraintLessThanOrEqualToAnchor:hud.bottomAnchor constant:-6.0],
	]];
}

- (void)buildExitButton {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	[button setTitle:@"退出" forState:UIControlStateNormal];
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
		[button.widthAnchor constraintEqualToConstant:64.0],
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
	NSString *text = status.length > 0 ? status : @"正在启动…";
	self.pendingStatus = text;
	if (self.displayView.hasFrame) {
		return;
	}
	self.statusLabel.text = text;
	self.statusHUD.hidden = NO;
	[self.spinner startAnimating];
}

- (void)updateFrameWidth:(uint32_t)width height:(uint32_t)height data:(NSData *)data {
	[self.displayView updateWithWidth:width height:height frame:data];
	[self.spinner stopAnimating];
	self.statusHUD.hidden = YES;
	// GPU 有画面就把终端让出去；没有画面时终端才是唯一能看的东西。
	self.terminalView.hidden = YES;
}

- (void)clearFrame {
	[self.displayView clearFrame];
	self.terminalView.hidden = NO;
	self.statusHUD.hidden = NO;
	[self.spinner startAnimating];
}

/// 串口文本不再按行贴到 UITextView：字符网格由终端自己维护，
/// 这里只负责在还没画面时保证终端可见。
- (void)appendConsoleLine:(NSString *)line {
	if (line.length > 0 && self.displayView.hasFrame) {
		return;
	}
	self.terminalView.hidden = NO;
}

#pragma mark - 动作

- (void)exitTapped {
	if (self.dismissHandler != nil) {
		self.dismissHandler();
	}
	[self dismissViewControllerAnimated:NO completion:nil];
}

- (void)keyboardTapped {
	[self.keyboardInput show];
}

@end
