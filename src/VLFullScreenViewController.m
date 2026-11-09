// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLFullScreenViewController.h"

#import <GameController/GameController.h>

#import "VLControlBar.h"
#import "VLKeyInputView.h"
#import "VLLinuxVirtualMachine.h"
#import "VLTerminalEmulator.h"
#import "VLTerminalView.h"

static NSString *const VLControlBarCornerKey = @"VLControlBarCorner";
static NSString *const VLControlBarOpacityKey = @"VLControlBarOpacity";

@interface VLFullScreenViewController ()

@property (nonatomic, strong) VLLinuxVirtualMachine *machine;
@property (nonatomic, strong) VLKeyInputView *keyInputView;
@property (nonatomic, strong) VLDisplayView *displayView;
/// 客户机串口控制台：80x25 字符网格，安装器和 shell 的界面都画在这里。
@property (nonatomic, strong) VLTerminalView *terminalView;

@property (nonatomic, strong) UIView *statusHUD;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
/// 页面还没加载完就收到状态时先存下来，viewDidLoad 再补上。
@property (nonatomic, copy) NSString *pendingStatus;
@property (nonatomic, strong) VLControlBar *controlBar;
/// 进来之前的分栏显示模式，退出时还原，别把设置页的侧栏弄丢。
@property (nonatomic, assign) UISplitViewControllerDisplayMode previousDisplayMode;
@property (nonatomic, assign) BOOL displayModeOverridden;

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

	[self buildDisplay];
	[self buildTerminal];
	[self buildStatusHUD];
	[self buildKeyInput];
	// 控制条最后加，保证它压在底部按键栏上面。
	[self buildControlBar];

	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	[center addObserver:self selector:@selector(hardwareKeyboardChanged)
				   name:GCKeyboardDidConnectNotification object:nil];
	[center addObserver:self selector:@selector(hardwareKeyboardChanged)
				   name:GCKeyboardDidDisconnectNotification object:nil];

	if (self.pendingStatus.length > 0) {
		self.statusLabel.text = self.pendingStatus;
	}
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// 这是一个独立页面，不是弹窗：进来就把设置页的导航栏收掉，退出时再还原。
	self.navigationController.navigationBarHidden = YES;
	// 客户机画面要占满整屏：把分栏收成单栏，侧栏整块隐藏。
	UISplitViewController *split = self.splitViewController;
	if (split != nil && !self.displayModeOverridden) {
		self.previousDisplayMode = split.preferredDisplayMode;
		self.displayModeOverridden = YES;
		split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	self.navigationController.navigationBarHidden = NO;
	UISplitViewController *split = self.splitViewController;
	if (split != nil && self.displayModeOverridden) {
		self.displayModeOverridden = NO;
		split.preferredDisplayMode = self.previousDisplayMode;
	}
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	// 侧滑返回不会走 dismissHandler，这里补上，否则详情页再也不会自动切回画面。
	if (self.isMovingFromParentViewController && self.dismissHandler != nil) {
		self.dismissHandler();
	}
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	// 硬件键盘事件只发给第一响应者；页面一出现就抢过来，不用先点一下。
	[self.keyInputView focus];
	[self hardwareKeyboardChanged];
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
		// 底部空出 48 点给单键栏，终端不能被它压住。
		[terminal.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-48.0],
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

- (void)buildControlBar {
	__weak typeof(self) weakSelf = self;
	VLControlBar *bar = [[VLControlBar alloc] initWithKeyboardHandler:^{
		[weakSelf.keyInputView showSoftKeyboard];
	}];
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	// 角位置和透明度都记在设置里，下次进来还是上次那套。
	if ([defaults objectForKey:VLControlBarCornerKey] != nil) {
		bar.corner = (VLControlBarCorner)[defaults integerForKey:VLControlBarCornerKey];
	}
	bar.barOpacity = [defaults objectForKey:VLControlBarOpacityKey] != nil
		? [defaults doubleForKey:VLControlBarOpacityKey]
		: 0.85;
	self.controlBar = bar;
	[self.view addSubview:bar];
	bar.menu = [self controlMenu];
}

/// 「更多」菜单：回到主页、软键盘、控制方式（按钮位置与透明度）。
- (UIMenu *)controlMenu {
	__weak typeof(self) weakSelf = self;
	UIAction *home = [UIAction actionWithTitle:@"回到主页"
										image:[UIImage systemImageNamed:@"house"]
								   identifier:nil
									  handler:^(__kindof UIAction *action) {
		[weakSelf exitTapped];
	}];
	UIAction *keyboard = [UIAction actionWithTitle:@"软键盘"
											image:[UIImage systemImageNamed:@"keyboard"]
									   identifier:nil
										  handler:^(__kindof UIAction *action) {
		[weakSelf.keyInputView showSoftKeyboard];
	}];

	NSArray<NSString *> *cornerTitles = @[ @"左上", @"右上", @"左下", @"右下" ];
	NSMutableArray<UIAction *> *cornerActions = [NSMutableArray array];
	for (NSInteger index = 0; index < (NSInteger)cornerTitles.count; index++) {
		UIAction *action = [UIAction actionWithTitle:cornerTitles[index]
											  image:nil
										 identifier:nil
											handler:^(__kindof UIAction *selected) {
			[weakSelf changeCorner:(VLControlBarCorner)index];
		}];
		action.state = weakSelf.controlBar.corner == (VLControlBarCorner)index
			? UIMenuElementStateOn : UIMenuElementStateOff;
		[cornerActions addObject:action];
	}
	UIMenu *cornerMenu = [UIMenu menuWithTitle:@"按钮位置"
										 image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"]
									identifier:nil
									   options:0
									  children:cornerActions];

	NSArray<NSNumber *> *opacities = @[ @0.3, @0.5, @0.7, @0.9 ];
	NSMutableArray<UIAction *> *opacityActions = [NSMutableArray array];
	for (NSNumber *value in opacities) {
		UIAction *action = [UIAction actionWithTitle:
							   [NSString stringWithFormat:@"%d%%", (int)(value.doubleValue * 100.0)]
											  image:nil
										 identifier:nil
											handler:^(__kindof UIAction *selected) {
			[weakSelf changeOpacity:value.doubleValue];
		}];
		action.state = ABS(weakSelf.controlBar.barOpacity - value.doubleValue) < 0.01
			? UIMenuElementStateOn : UIMenuElementStateOff;
		[opacityActions addObject:action];
	}
	UIMenu *opacityMenu = [UIMenu menuWithTitle:@"按钮透明度"
										  image:[UIImage systemImageNamed:@"circle.lefthalf.filled"]
									 identifier:nil
										options:0
									   children:opacityActions];
	UIMenu *settings = [UIMenu menuWithTitle:@"控制方式"
									   image:[UIImage systemImageNamed:@"slider.horizontal.3"]
								  identifier:nil
									 options:0
									children:@[ cornerMenu, opacityMenu ]];
	return [UIMenu menuWithTitle:@"" children:@[ home, keyboard, settings ]];
}

- (void)changeCorner:(VLControlBarCorner)corner {
	self.controlBar.corner = corner;
	[NSUserDefaults.standardUserDefaults setInteger:corner forKey:VLControlBarCornerKey];
	self.controlBar.menu = [self controlMenu];
}

- (void)changeOpacity:(CGFloat)opacity {
	self.controlBar.barOpacity = opacity;
	[NSUserDefaults.standardUserDefaults setDouble:opacity forKey:VLControlBarOpacityKey];
	self.controlBar.menu = [self controlMenu];
}

/// 接上外接键盘就收起屏幕键盘按钮，只剩「更多」一个圆；拔掉再长回来。
- (void)hardwareKeyboardChanged {
	self.controlBar.keyboardButtonVisible = ([GCKeyboard coalescedKeyboard] == nil);
}

/// 底部一条固定的单键栏（Esc/Tab/方向/回车/退格），同时它也负责接外接键盘。
/// 系统软键盘只在控制条上点了键盘按钮时才唤起，不再常驻。
- (void)buildKeyInput {
	VLKeyInputView *keys = [[VLKeyInputView alloc] initWithMachine:self.machine];
	keys.translatesAutoresizingMaskIntoConstraints = NO;
	self.keyInputView = keys;
	[self.view addSubview:keys];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[keys.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
		[keys.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[keys.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
		[keys.heightAnchor constraintEqualToConstant:44.0],
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
	// 本页是导航栈里的子页面，退出去就是 pop；没有导航栈时再退回弹窗式关闭。
	UINavigationController *navigation = self.navigationController;
	if (navigation != nil && navigation.viewControllers.count > 1) {
		[navigation popViewControllerAnimated:YES];
	} else {
		[self dismissViewControllerAnimated:YES completion:nil];
	}
}

@end