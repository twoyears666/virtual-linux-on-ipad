#import "VLFullScreenViewController.h"

#import "VLKeyboardInput.h"
#import "VLLinuxVirtualMachine.h"

@interface VLFullScreenViewController ()

@property (nonatomic, strong) VLLinuxVirtualMachine *machine;
@property (nonatomic, strong) VLKeyboardInput *keyboardInput;
@property (nonatomic, strong) VLDisplayView *displayView;
@property (nonatomic, strong) UITextView *consoleView;
@property (nonatomic, strong) NSMutableArray<NSString *> *consoleLines;

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

	self.consoleLines = [NSMutableArray array];
	self.keyboardInput = [[VLKeyboardInput alloc] initWithMachine:self.machine];
	[self.keyboardInput attachToView:self.view];

	[self buildDisplay];
	[self buildConsole];
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

/// 客户机画面：铺满整屏，按 4:3 等比缩放，多余的地方自然留黑边。
- (void)buildDisplay {
	VLDisplayView *display = [[VLDisplayView alloc] init];
	display.translatesAutoresizingMaskIntoConstraints = NO;
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

	[NSLayoutConstraint activateConstraints:@[
		[display.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[display.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[display.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[display.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

/// 没有画面时这一页显示客户机串口输出：内核启动日志，而不是一行状态字。
- (void)buildConsole {
	UITextView *console = [[UITextView alloc] init];
	console.translatesAutoresizingMaskIntoConstraints = NO;
	console.backgroundColor = UIColor.clearColor;
	console.editable = NO;
	console.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
	console.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
	console.textContainerInset = UIEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);
	console.alwaysBounceVertical = YES;
	self.consoleView = console;
	[self.view addSubview:console];

	// 页面创建到真正显示之间可能已经有串口输出了，先补上。
	if (self.consoleLines.count > 0) {
		console.text = [self.consoleLines componentsJoinedByString:@"\n"];
	}

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[console.topAnchor constraintEqualToAnchor:safe.topAnchor constant:64.0],
		[console.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0],
		[console.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20.0],
		[console.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-64.0],
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
	self.consoleView.hidden = YES;
}

- (void)clearFrame {
	[self.displayView clearFrame];
	self.consoleView.hidden = NO;
	self.statusHUD.hidden = NO;
	[self.spinner startAnimating];
}

- (void)appendConsoleLine:(NSString *)line {
	NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if (trimmed.length == 0) {
		return;
	}

	// 页面还没显示出来时也要把日志攒住，等 buildConsole 再补上。
	if (self.consoleLines == nil) {
		self.consoleLines = [NSMutableArray array];
	}

	// 用户自己翻上去看日志时不要把他拽回底部。
	CGFloat contentHeight = self.consoleView.contentSize.height;
	CGFloat visibleBottom = self.consoleView.contentOffset.y + CGRectGetHeight(self.consoleView.bounds);
	BOOL followTail = contentHeight <= 0.0 || visibleBottom >= contentHeight - 40.0;

	[self.consoleLines addObject:trimmed];
	const NSUInteger maximumLines = 400;
	if (self.consoleLines.count > maximumLines) {
		[self.consoleLines removeObjectsInRange:NSMakeRange(0, self.consoleLines.count - maximumLines)];
	}
	if (self.consoleView == nil) {
		return;
	}
	self.consoleView.text = [self.consoleLines componentsJoinedByString:@"\n"];

	if (followTail) {
		CGPoint bottom = CGPointMake(0.0, MAX(0.0, self.consoleView.contentSize.height -
												   CGRectGetHeight(self.consoleView.bounds)));
		[self.consoleView setContentOffset:bottom animated:NO];
	}
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
