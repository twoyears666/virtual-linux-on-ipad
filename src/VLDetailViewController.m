#import "VLDetailViewController.h"

#import <math.h>

#import "VLDashedPlaceholderView.h"
#import "VLDisplayView.h"
#import "VLFullScreenViewController.h"
#import "VLHostCapabilities.h"
#import "VLLinuxVirtualMachine.h"
#import "VLLog.h"
#import "VLStartupLog.h"
#import "VLVMStore.h"

/// iOS 字符 → Linux evdev 按键码（KEY_A = 30 这一套）。
/// 返回值 0 表示这个字符没有对应按键，直接忽略。
static const uint16_t VLLowercaseKeycodes[26] = {
	30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
	49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
};

static uint16_t VLKeycodeForCharacter(unichar character, BOOL *needsShift) {
	if (needsShift != NULL) {
		*needsShift = NO;
	}
	if (character >= 'a' && character <= 'z') {
		return VLLowercaseKeycodes[character - 'a'];
	}
	if (character >= 'A' && character <= 'Z') {
		if (needsShift != NULL) {
			*needsShift = YES;
		}
		return VLLowercaseKeycodes[character - 'A'];
	}
	if (character >= '1' && character <= '9') {
		return (uint16_t)(character - '1' + 2);
	}
	if (character == '0') {
		return 11;
	}
	if (character == ' ') {
		return 57;
	}
	if (character == '\n' || character == '\r') {
		return 28;
	}
	if (character == '\t') {
		return 15;
	}
	switch (character) {
		case '-': return 12;
		case '=': return 13;
		case '[': return 26;
		case ']': return 27;
		case ';': return 39;
		case '\'': return 40;
		case '`': return 41;
		case '\\': return 43;
		case ',': return 51;
		case '.': return 52;
		case '/': return 53;
		// 下面这些是按住 Shift 才打出来的符号。
		case '!': if (needsShift != NULL) { *needsShift = YES; } return 2;
		case '@': if (needsShift != NULL) { *needsShift = YES; } return 3;
		case '#': if (needsShift != NULL) { *needsShift = YES; } return 4;
		case '$': if (needsShift != NULL) { *needsShift = YES; } return 5;
		case '%': if (needsShift != NULL) { *needsShift = YES; } return 6;
		case '^': if (needsShift != NULL) { *needsShift = YES; } return 7;
		case '&': if (needsShift != NULL) { *needsShift = YES; } return 8;
		case '*': if (needsShift != NULL) { *needsShift = YES; } return 9;
		case '(': if (needsShift != NULL) { *needsShift = YES; } return 10;
		case ')': if (needsShift != NULL) { *needsShift = YES; } return 11;
		case '_': if (needsShift != NULL) { *needsShift = YES; } return 12;
		case '+': if (needsShift != NULL) { *needsShift = YES; } return 13;
		case '{': if (needsShift != NULL) { *needsShift = YES; } return 26;
		case '}': if (needsShift != NULL) { *needsShift = YES; } return 27;
		case ':': if (needsShift != NULL) { *needsShift = YES; } return 39;
		case '"': if (needsShift != NULL) { *needsShift = YES; } return 40;
		case '~': if (needsShift != NULL) { *needsShift = YES; } return 41;
		case '|': if (needsShift != NULL) { *needsShift = YES; } return 43;
		case '<': if (needsShift != NULL) { *needsShift = YES; } return 51;
		case '>': if (needsShift != NULL) { *needsShift = YES; } return 52;
		case '?': if (needsShift != NULL) { *needsShift = YES; } return 53;
	}
	return 0;
}

@interface VLDetailViewController () <VLLinuxVirtualMachineDelegate, UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UILabel *cpuValueLabel;
@property (nonatomic, strong) UILabel *memoryValueLabel;
@property (nonatomic, strong) NSMutableArray<UILabel *> *diskValueLabels;
@property (nonatomic, strong) UIButton *resolutionButton;
@property (nonatomic, strong) UILabel *statusLabel;

@property (nonatomic, strong) VLLinuxVirtualMachine *virtualMachine;
@property (nonatomic, strong) VLDisplayView *displayView;
/// 藏在界面之外的输入框：只为弹出系统键盘，敲的字都转成按键事件送进客户机。
@property (nonatomic, strong) UITextField *keyboardField;
/// 运行时的全屏画面；启动成功后立刻盖上来。
@property (nonatomic, strong) VLFullScreenViewController *fullScreenController;
/// 用户自己点过「退出全屏」：别再自动弹回去，等下次启动再说。
@property (nonatomic, assign) BOOL fullScreenSuppressedByUser;

@end

@implementation VLDetailViewController

- (void)viewDidLoad {
	[super viewDidLoad];

	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

	self.scrollView = [[UIScrollView alloc] init];
	self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	self.scrollView.alwaysBounceVertical = YES;
	self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	[self.view addSubview:self.scrollView];

	self.stackView = [[UIStackView alloc] init];
	self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
	self.stackView.axis = UILayoutConstraintAxisVertical;
	self.stackView.spacing = 16.0;
	[self.scrollView addSubview:self.stackView];

	[NSLayoutConstraint activateConstraints:@[
		[self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
		[self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16.0],
		[self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
		[self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
		[self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24.0],
	]];

	[self rebuildContent];
}

- (void)setConfiguration:(VLVMConfiguration *)configuration {
	// 换到另一台机器时，先把上一台的 vCPU 停掉，避免两层画面同时刷新。
	if (_configuration != configuration && [self isMachineActive]) {
		[self.virtualMachine stop];
	}
	_configuration = configuration;
	self.title = configuration != nil ? configuration.name : @"虚拟机";

	if (self.isViewLoaded) {
		[self rebuildContent];
	}
}

- (void)dealloc {
	[_virtualMachine stop];
}

- (void)rebuildContent {
	[VLStartupLog log:@"详情界面 重建开始"];

	self.diskValueLabels = [NSMutableArray array];

	for (UIView *view in self.stackView.arrangedSubviews) {
		[self.stackView removeArrangedSubview:view];
		[view removeFromSuperview];
	}

	if (self.configuration == nil) {
		UILabel *emptyLabel = [[UILabel alloc] init];
		emptyLabel.text = @"在左侧选择一台虚拟机。";
		emptyLabel.textColor = UIColor.secondaryLabelColor;
		emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
		[self.stackView addArrangedSubview:emptyLabel];
		return;
	}

	VLVMConfiguration *configuration = self.configuration;
	// 存放目录不在了（外接盘拔出、目录被删）就冻结：不给启动，其余设置仍可查看。
	BOOL frozen = !configuration.isStorageAvailable;

	if (frozen) {
		[self.stackView addArrangedSubview:[self frozenBannerView]];
	}

	// 客户机跑起来就换成真实画面（4:3），没跑时用虚线框占位，点按即启动。
	if ([self isMachineActive]) {
		[self.stackView addArrangedSubview:[self displayAreaView]];
	} else {
		VLDashedPlaceholderView *placeholder = [[VLDashedPlaceholderView alloc] init];
		placeholder.translatesAutoresizingMaskIntoConstraints = NO;
		placeholder.text = frozen
			? @"已冻结\n存放位置不可用，恢复目录后自动解冻"
			: [NSString stringWithFormat:@"虚拟机截图\n运行后在此显示 %@ 的客户机画面", configuration.resolutionString];
		__weak typeof(self) weakSelf = self;
		if (!frozen) {
			placeholder.onTap = ^{
				[weakSelf startTapped];
			};
		}
		// 4:3（iPad 常见比例），宽度撑满、高度按比例算。
		[placeholder.heightAnchor constraintEqualToAnchor:placeholder.widthAnchor multiplier:0.75].active = YES;
		if (frozen) {
			placeholder.alpha = 0.55;
			placeholder.userInteractionEnabled = NO;
		}
		[self.stackView addArrangedSubview:placeholder];
	}
	[VLStartupLog log:@"详情界面 画面区域完成"];

	// 基本信息
	self.nameField = [self textFieldWithPlaceholder:@"虚拟机名称"
											  text:configuration.name
											action:@selector(nameChanged:)];
	self.nameField.textColor = UIColor.labelColor;
	self.nameField.textAlignment = NSTextAlignmentRight;

	[self.stackView addArrangedSubview:[self cardWithTitle:@"基本信息" rows:@[
		[self rowWithTitle:@"名称" control:self.nameField],
		[self rowWithTitle:@"备注" control:[self textFieldWithPlaceholder:@"可选"
																	  text:configuration.notes
																	action:@selector(notesChanged:)]],
	]]];
	[VLStartupLog log:@"详情界面 基本信息卡片完成"];

	// 系统
	[self.stackView addArrangedSubview:[self cardWithTitle:@"系统" rows:@[
		[self rowWithTitle:@"内核" control:[self textFieldWithPlaceholder:@"vmlinuz 路径"
																	text:configuration.kernelPath
																  action:@selector(kernelPathChanged:)]],
		[self rowWithTitle:@"初始内存盘" control:[self textFieldWithPlaceholder:@"可选"
																		  text:configuration.initrdPath
																		action:@selector(initrdPathChanged:)]],
		[self rowWithTitle:@"客户机架构" control:[self valueLabelWithText:@"arm64"]],
		[self rowWithTitle:@"安装镜像" control:[self valueLabelWithText:configuration.isoPath.length > 0
																		? configuration.isoPath.lastPathComponent
																		: @"未导入"]],
	]]];
	[VLStartupLog log:@"详情界面 系统卡片完成"];

	// 硬件：内存上限跟随本机物理内存（75%，至少给系统留 1 GB）
	self.cpuValueLabel = [self valueLabelWithText:[NSString stringWithFormat:@"%lu 核", (unsigned long)configuration.cpuCores]];
	UISlider *cpuSlider = [self sliderWithMin:1.0
										  max:8.0
										value:(CGFloat)configuration.cpuCores
									   action:@selector(cpuSliderChanged:)];

	NSUInteger maximumMemoryMB = [VLHostCapabilities maximumGuestMemoryMB];
	if (configuration.memoryMB > maximumMemoryMB) {
		configuration.memoryMB = maximumMemoryMB;
	}
	self.memoryValueLabel =
		[self valueLabelWithText:[NSString stringWithFormat:@"%lu MB", (unsigned long)configuration.memoryMB]];
	UISlider *memorySlider = [self sliderWithMin:512.0
											 max:(CGFloat)maximumMemoryMB
										   value:(CGFloat)configuration.memoryMB
										  action:@selector(memorySliderChanged:)];

	[self.stackView addArrangedSubview:[self cardWithTitle:@"硬件" rows:@[
		[self blockRowWithTitle:@"CPU 核心数" control:cpuSlider valueLabel:self.cpuValueLabel],
		[self blockRowWithTitle:@"内存" control:memorySlider valueLabel:self.memoryValueLabel],
	]]];
	[VLStartupLog log:@"详情界面 硬件卡片完成"];

	// 存储：多块盘各自独立，第一块是系统盘；镜像尚未创建前容量随意改
	NSMutableArray<UIView *> *storageRows = [NSMutableArray array];
	NSUInteger diskIndex = 0;
	for (VLDiskImage *disk in configuration.disks) {
		[storageRows addObject:[self diskBlockForDisk:disk index:diskIndex]];
		diskIndex++;
	}

	// 镜像已创建后磁盘布局固定：不能再拖动容量，也不能再加/删磁盘。
	if (!configuration.diskImageReady) {
		UIButton *addDiskButton = [UIButton buttonWithType:UIButtonTypeSystem];
		[addDiskButton setTitle:@"＋ 添加磁盘" forState:UIControlStateNormal];
		addDiskButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
		[addDiskButton addTarget:self action:@selector(addDiskTapped) forControlEvents:UIControlEventTouchUpInside];
		[storageRows addObject:addDiskButton];
	}

	UILabel *diskNote = [[UILabel alloc] init];
	diskNote.text = configuration.diskImageReady
		? @"磁盘镜像已创建，容量与数量均已锁定"
		: @"每块盘是独立镜像，创建镜像前容量随意改；镜像创建后锁定";
	diskNote.numberOfLines = 0;
	diskNote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	diskNote.textColor = UIColor.secondaryLabelColor;
	[storageRows addObject:diskNote];

	[self.stackView addArrangedSubview:[self cardWithTitle:@"存储" rows:storageRows]];
	[VLStartupLog log:@"详情界面 存储卡片完成"];

	// 显示
	self.resolutionButton = [self resolutionButtonWithConfiguration:configuration];

	UISegmentedControl *scale =
		[self segmentedControlWithTitles:@[ @"适应", @"填充", @"原始" ]
								selected:(NSInteger)configuration.displayScale
								  action:@selector(displayScaleChanged:)];

	UISegmentedControl *frameRate =
		[self segmentedControlWithTitles:@[ @"30 fps", @"60 fps", @"不限制" ]
								selected:(NSInteger)configuration.frameRateLimit
								  action:@selector(frameRateLimitChanged:)];

	[self.stackView addArrangedSubview:[self cardWithTitle:@"显示" rows:@[
		[self rowWithTitle:@"分辨率" control:self.resolutionButton],
		[self blockRowWithTitle:@"缩放" control:scale valueLabel:nil],
		[self rowWithTitle:@"帧率上限" control:frameRate],
		[self rowWithTitle:@"显示设备" control:[self valueLabelWithText:@"virtio-gpu"]],
	]]];
	[VLStartupLog log:@"详情界面 显示卡片完成"];

	// 网络
	UISegmentedControl *network =
		[self segmentedControlWithTitles:@[ @"共享", @"桥接", @"无" ]
								selected:(NSInteger)configuration.networkMode
								  action:@selector(networkModeChanged:)];
	NSMutableArray<UIView *> *networkRows = [NSMutableArray array];
	[networkRows addObject:[self blockRowWithTitle:@"网络模式" control:network valueLabel:nil]];
	[networkRows addObject:[self rowWithTitle:@"MAC 地址"
									  control:[self textFieldWithPlaceholder:@"52:54:00:12:34:56"
																		text:configuration.macAddress
																	  action:@selector(macAddressChanged:)]]];

	if (configuration.portForwards.count == 0) {
		[networkRows addObject:[self rowWithTitle:@"端口转发" control:[self valueLabelWithText:@"尚未添加"]]];
	}
	NSUInteger forwardIndex = 0;
	for (VLPortForward *forward in configuration.portForwards) {
		[networkRows addObject:[self portForwardRow:forward index:forwardIndex]];
		forwardIndex++;
	}

	UIButton *addForwardButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[addForwardButton setTitle:@"＋ 添加端口转发" forState:UIControlStateNormal];
	addForwardButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	[addForwardButton addTarget:self
						 action:@selector(addPortForwardTapped)
			   forControlEvents:UIControlEventTouchUpInside];
	[networkRows addObject:addForwardButton];

	[self.stackView addArrangedSubview:[self cardWithTitle:@"网络" rows:networkRows]];
	[VLStartupLog log:@"详情界面 网络卡片完成"];

	// 输入
	UISegmentedControl *input =
		[self segmentedControlWithTitles:@[ @"直接触控", @"指针" ]
								selected:(NSInteger)configuration.inputMode
								  action:@selector(inputModeChanged:)];
	[self.stackView addArrangedSubview:[self cardWithTitle:@"输入" rows:@[
		[self blockRowWithTitle:@"触控模式" control:input valueLabel:nil],
		[self rowWithTitle:@"捕获鼠标" control:[self switchWithOn:configuration.mouseCapture
													   action:@selector(mouseCaptureChanged:)]],
		[self rowWithTitle:@"捕获外接键盘" control:[self switchWithOn:configuration.keyboardCapture
															 action:@selector(keyboardCaptureChanged:)]],
	]]];
	[VLStartupLog log:@"详情界面 输入卡片完成"];

	// 运行环境：Hypervisor 是否可用直接摆在这里，省得再去翻日志。
	UILabel *environmentLabel = [[UILabel alloc] init];
	environmentLabel.numberOfLines = 0;
	environmentLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
	environmentLabel.textColor = UIColor.secondaryLabelColor;
	environmentLabel.text = [VLHostCapabilities diagnosticReport];

	[self.stackView addArrangedSubview:[self cardWithTitle:@"运行环境" rows:@[ environmentLabel ]]];
	[VLStartupLog log:@"详情界面 运行环境卡片完成"];

	// 启动 / 停止
	BOOL machineActive = [self isMachineActive];
	UIButton *startButton = [UIButton buttonWithType:UIButtonTypeSystem];
	startButton.translatesAutoresizingMaskIntoConstraints = NO;
	[startButton setTitle:(machineActive ? @"停止虚拟机" : @"启动虚拟机") forState:UIControlStateNormal];
	startButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
	[startButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	startButton.backgroundColor = machineActive ? UIColor.systemRedColor : self.view.tintColor;
	startButton.layer.cornerRadius = 12.0;
	[startButton addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
	[startButton.heightAnchor constraintEqualToConstant:50.0].active = YES;
	[self.stackView addArrangedSubview:startButton];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.statusLabel.textColor = UIColor.secondaryLabelColor;
	self.statusLabel.text = [self machineStatusText];
	[self.stackView addArrangedSubview:self.statusLabel];

	[VLStartupLog log:@"详情界面 重建完成"];
}

#pragma mark - 控件构造

- (UILabel *)sectionTitleLabel:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	label.textColor = UIColor.labelColor;
	return label;
}

- (UILabel *)valueLabelWithText:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	label.textColor = UIColor.secondaryLabelColor;
	label.textAlignment = NSTextAlignmentRight;
	return label;
}

- (UIView *)cardWithTitle:(NSString *)title rows:(NSArray<UIView *> *)rows {
	UIView *card = [[UIView alloc] init];
	card.translatesAutoresizingMaskIntoConstraints = NO;
	card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	card.layer.cornerRadius = 14.0;

	UIStackView *inner = [[UIStackView alloc] init];
	inner.translatesAutoresizingMaskIntoConstraints = NO;
	inner.axis = UILayoutConstraintAxisVertical;
	inner.spacing = 12.0;
	[inner addArrangedSubview:[self sectionTitleLabel:title]];
	for (UIView *row in rows) {
		[inner addArrangedSubview:row];
	}
	[card addSubview:inner];

	[NSLayoutConstraint activateConstraints:@[
		[inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
		[inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
		[inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
		[inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0],
	]];

	return card;
}

- (UIView *)rowWithTitle:(NSString *)title control:(UIView *)control {
	UIStackView *row = [[UIStackView alloc] init];
	row.axis = UILayoutConstraintAxisHorizontal;
	row.alignment = UIStackViewAlignmentCenter;
	row.spacing = 12.0;

	UILabel *label = [[UILabel alloc] init];
	label.text = title;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	label.textColor = UIColor.labelColor;
	[label setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];

	[control setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

	[row addArrangedSubview:label];
	[row addArrangedSubview:control];
	return row;
}

- (UIView *)blockRowWithTitle:(NSString *)title control:(UIView *)control valueLabel:(UILabel *)valueLabel {
	UIStackView *column = [[UIStackView alloc] init];
	column.axis = UILayoutConstraintAxisVertical;
	column.spacing = 8.0;

	UIStackView *headerRow = [[UIStackView alloc] init];
	headerRow.axis = UILayoutConstraintAxisHorizontal;
	headerRow.alignment = UIStackViewAlignmentCenter;
	headerRow.spacing = 8.0;

	UILabel *label = [[UILabel alloc] init];
	label.text = title;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	label.textColor = UIColor.labelColor;
	[headerRow addArrangedSubview:label];

	UIView *spacer = [[UIView alloc] init];
	[spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[headerRow addArrangedSubview:spacer];

	if (valueLabel != nil) {
		[headerRow addArrangedSubview:valueLabel];
	}

	[column addArrangedSubview:headerRow];
	[column addArrangedSubview:control];
	return column;
}

- (UITextField *)textFieldWithPlaceholder:(NSString *)placeholder text:(NSString *)text action:(SEL)action {
	UITextField *field = [[UITextField alloc] init];
	field.placeholder = placeholder;
	field.text = text;
	field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	field.textColor = UIColor.secondaryLabelColor;
	field.textAlignment = NSTextAlignmentRight;
	field.borderStyle = UITextBorderStyleNone;
	field.clearButtonMode = UITextFieldViewModeWhileEditing;
	field.returnKeyType = UIReturnKeyDone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	[field addTarget:self action:action forControlEvents:UIControlEventEditingChanged];
	return field;
}

- (UISwitch *)switchWithOn:(BOOL)on action:(SEL)action {
	UISwitch *toggle = [[UISwitch alloc] init];
	toggle.on = on;
	[toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
	return toggle;
}

- (UISlider *)sliderWithMin:(CGFloat)min max:(CGFloat)max value:(CGFloat)value action:(SEL)action {
	UISlider *slider = [[UISlider alloc] init];
	slider.minimumValue = (float)min;
	slider.maximumValue = (float)max;
	slider.value = (float)value;
	[slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
	return slider;
}

- (UISegmentedControl *)segmentedControlWithTitles:(NSArray<NSString *> *)titles
										  selected:(NSInteger)selected
											action:(SEL)action {
	UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:titles];
	if (selected >= 0 && selected < (NSInteger)titles.count) {
		control.selectedSegmentIndex = selected;
	}
	[control addTarget:self action:action forControlEvents:UIControlEventValueChanged];
	return control;
}

- (UIButton *)resolutionButtonWithConfiguration:(VLVMConfiguration *)configuration {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setTitle:configuration.resolutionString forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	button.showsMenuAsPrimaryAction = YES;
	button.menu = [self resolutionMenu];
	return button;
}

- (UIMenu *)resolutionMenu {
	__weak typeof(self) weakSelf = self;

	NSArray<NSNumber *> *values = @[
		@(VLDisplayResolutionNative),
		@(VLDisplayResolution1024x768),
		@(VLDisplayResolution1280x800),
		@(VLDisplayResolution1440x1080),
		@(VLDisplayResolution1920x1200),
	];

	NSMutableArray<UIAction *> *actions = [NSMutableArray array];
	for (NSNumber *value in values) {
		VLVMConfiguration *probe = [[VLVMConfiguration alloc] init];
		probe.resolution = (VLDisplayResolution)value.integerValue;
		NSString *title = probe.resolutionString;

		UIAction *action = [UIAction actionWithTitle:title
											   image:nil
										  identifier:nil
											 handler:^(UIAction *selectedAction) {
			weakSelf.configuration.resolution = (VLDisplayResolution)value.integerValue;
			[weakSelf.resolutionButton setTitle:title forState:UIControlStateNormal];
			[weakSelf notifyChange];
		}];
		action.state = weakSelf.configuration.resolution == value.integerValue ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}

	return [UIMenu menuWithTitle:@"分辨率" children:actions];
}

#pragma mark - 设置变更

- (void)notifyChange {
	// 设置一改就落盘，否则重启 App（以及覆盖安装）后配置就没了。
	[[VLVMStore sharedStore] save];
	[self.changeDelegate detailViewControllerDidChangeConfiguration:self];
}

- (void)nameChanged:(UITextField *)sender {
	self.configuration.name = sender.text;
	self.title = sender.text;
	[self notifyChange];
}

- (void)notesChanged:(UITextField *)sender {
	self.configuration.notes = sender.text;
	[self notifyChange];
}

- (void)kernelPathChanged:(UITextField *)sender {
	self.configuration.kernelPath = sender.text;
	[self notifyChange];
}

- (void)initrdPathChanged:(UITextField *)sender {
	self.configuration.initrdPath = sender.text;
	[self notifyChange];
}

- (void)macAddressChanged:(UITextField *)sender {
	self.configuration.macAddress = sender.text;
	[self notifyChange];
}

- (void)displayScaleChanged:(UISegmentedControl *)sender {
	self.configuration.displayScale = (VLDisplayScale)sender.selectedSegmentIndex;
	[self notifyChange];
}

- (void)networkModeChanged:(UISegmentedControl *)sender {
	self.configuration.networkMode = (VLNetworkMode)sender.selectedSegmentIndex;
	[self notifyChange];
}

- (void)inputModeChanged:(UISegmentedControl *)sender {
	self.configuration.inputMode = (VLInputMode)sender.selectedSegmentIndex;
	[self notifyChange];
}

- (void)mouseCaptureChanged:(UISwitch *)sender {
	self.configuration.mouseCapture = sender.isOn;
	[self notifyChange];
}

- (void)keyboardCaptureChanged:(UISwitch *)sender {
	self.configuration.keyboardCapture = sender.isOn;
	[self notifyChange];
}

- (void)cpuSliderChanged:(UISlider *)sender {
	NSUInteger cores = (NSUInteger)MAX(1.0, roundf(sender.value));
	sender.value = (float)cores;
	self.configuration.cpuCores = cores;
	self.cpuValueLabel.text = [NSString stringWithFormat:@"%lu 核", (unsigned long)cores];
	[self notifyChange];
}

- (void)memorySliderChanged:(UISlider *)sender {
	NSUInteger megabytes = (NSUInteger)(MAX(512.0, roundf(sender.value / 512.0)) * 512.0);
	sender.value = (float)megabytes;
	self.configuration.memoryMB = megabytes;
	self.memoryValueLabel.text = [NSString stringWithFormat:@"%lu MB", (unsigned long)megabytes];
	[self notifyChange];
}

- (void)diskSliderChanged:(UISlider *)sender {
	NSUInteger gigabytes = (NSUInteger)(MAX(4.0, roundf(sender.value / 4.0)) * 4.0);
	sender.value = (float)gigabytes;

	NSInteger index = sender.tag;
	if (index < 0 || index >= (NSInteger)self.configuration.disks.count) {
		return;
	}
	self.configuration.disks[(NSUInteger)index].sizeGB = gigabytes;
	if (index < (NSInteger)self.diskValueLabels.count) {
		self.diskValueLabels[(NSUInteger)index].text =
			[NSString stringWithFormat:@"%lu GB", (unsigned long)gigabytes];
	}
	[self notifyChange];
}

- (void)frameRateLimitChanged:(UISegmentedControl *)sender {
	self.configuration.frameRateLimit = (VLFrameRateLimit)sender.selectedSegmentIndex;
	[self notifyChange];
}

- (UIView *)portForwardRow:(VLPortForward *)forward index:(NSUInteger)index {
	UILabel *valueLabel = [self valueLabelWithText:forward.displayString];

	UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[removeButton setTitle:@"移除" forState:UIControlStateNormal];
	removeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	[removeButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
	removeButton.tag = (NSInteger)index;
	[removeButton addTarget:self
					 action:@selector(removePortForwardTapped:)
		   forControlEvents:UIControlEventTouchUpInside];

	UIStackView *control = [[UIStackView alloc] initWithArrangedSubviews:@[ valueLabel, removeButton ]];
	control.axis = UILayoutConstraintAxisHorizontal;
	control.spacing = 8.0;
	control.alignment = UIStackViewAlignmentCenter;
	return [self rowWithTitle:@"端口转发" control:control];
}

- (void)addPortForwardTapped {
	UIAlertController *alert =
		[UIAlertController alertControllerWithTitle:@"添加端口转发"
											message:@"把 iPad 上的端口转发到客户机端口"
									 preferredStyle:UIAlertControllerStyleAlert];

	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"主机端口（如 8080）";
		field.keyboardType = UIKeyboardTypeNumberPad;
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"客户机端口（如 80）";
		field.keyboardType = UIKeyboardTypeNumberPad;
	}];

	__weak typeof(self) weakSelf = self;
	void (^commit)(NSString *protocol) = ^(NSString *protocol) {
		[weakSelf commitPortForwardFromAlert:alert protocol:protocol];
	};

	[alert addAction:[UIAlertAction actionWithTitle:@"添加 TCP"
											  style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *action) {
		commit(@"TCP");
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"添加 UDP"
											  style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *action) {
		commit(@"UDP");
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"取消"
											  style:UIAlertActionStyleCancel
											handler:nil]];

	[self presentViewController:alert animated:YES completion:nil];
}

- (void)commitPortForwardFromAlert:(UIAlertController *)alert protocol:(NSString *)protocol {
	NSArray<UITextField *> *fields = alert.textFields;
	NSInteger hostPort = fields.count > 0 ? fields[0].text.integerValue : 0;
	NSInteger guestPort = fields.count > 1 ? fields[1].text.integerValue : 0;

	if (hostPort <= 0 || hostPort > 65535 || guestPort <= 0 || guestPort > 65535) {
		UIAlertController *error =
			[UIAlertController alertControllerWithTitle:@"端口无效"
												message:@"端口必须是 1 – 65535 之间的整数。"
										 preferredStyle:UIAlertControllerStyleAlert];
		[error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:error animated:YES completion:nil];
		return;
	}

	VLPortForward *forward = [VLPortForward forwardWithHostPort:(NSUInteger)hostPort
													  guestPort:(NSUInteger)guestPort
													   protocol:protocol];
	[self.configuration.portForwards addObject:forward];
	[VLStartupLog log:@"项目添加端口转发：%@", forward.displayString];
	[self reloadKeepingScrollPosition];
	[self notifyChange];
}

- (void)removePortForwardTapped:(UIButton *)sender {
	NSInteger index = sender.tag;
	if (index < 0 || index >= (NSInteger)self.configuration.portForwards.count) {
		return;
	}
	VLPortForward *forward = self.configuration.portForwards[(NSUInteger)index];
	[self.configuration.portForwards removeObjectAtIndex:(NSUInteger)index];
	[VLStartupLog log:@"项目移除端口转发：%@", forward.displayString];
	[self reloadKeepingScrollPosition];
	[self notifyChange];
}

/// 重建后把滚动位置还原，免得点一下按钮就跳回顶部。
- (void)reloadKeepingScrollPosition {
	CGPoint offset = self.scrollView.contentOffset;
	[self rebuildContent];
	dispatch_async(dispatch_get_main_queue(), ^{
		CGFloat maximum = MAX(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.size.height);
		self.scrollView.contentOffset = CGPointMake(0.0, MIN(offset.y, maximum));
	});
}

- (void)addDiskTapped {
	// 新盘默认 8 GB，容量可在下面那条滑块上改。
	[self.configuration addDiskWithSizeGB:8];
	[VLStartupLog log:@"项目添加磁盘：现共 %lu 块", (unsigned long)self.configuration.disks.count];
	[self rebuildContent];
	[self notifyChange];
}

- (void)removeDiskTapped:(UIButton *)sender {
	NSInteger index = sender.tag;
	if (index < 0 || index >= (NSInteger)self.configuration.disks.count) {
		return;
	}
	[self.configuration removeDisk:self.configuration.disks[(NSUInteger)index]];
	[VLStartupLog log:@"项目移除磁盘：现共 %lu 块", (unsigned long)self.configuration.disks.count];
	[self rebuildContent];
	[self notifyChange];
}

- (UIView *)diskBlockForDisk:(VLDiskImage *)disk index:(NSUInteger)index {
	UILabel *valueLabel =
		[self valueLabelWithText:[NSString stringWithFormat:@"%lu GB", (unsigned long)disk.sizeGB]];
	[self.diskValueLabels addObject:valueLabel];

	UISlider *slider = [self sliderWithMin:4.0
									   max:64.0
									 value:(CGFloat)disk.sizeGB
									action:@selector(diskSliderChanged:)];
	slider.tag = (NSInteger)index;
	if (self.configuration.diskImageReady) {
		// 镜像已落地，容量不可再改，避免出现「界面 32 GB、文件还是 16 GB」。
		slider.userInteractionEnabled = NO;
		slider.alpha = 0.4;
	}

	UIView *block = [self blockRowWithTitle:disk.name control:slider valueLabel:valueLabel];
	if (index == 0 || self.configuration.diskImageReady) {
		// 第一块是系统盘；镜像创建后也不再允许删盘。
		return block;
	}

	UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[removeButton setTitle:@"移除该磁盘" forState:UIControlStateNormal];
	removeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	[removeButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
	removeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
	removeButton.tag = (NSInteger)index;
	[removeButton addTarget:self action:@selector(removeDiskTapped:) forControlEvents:UIControlEventTouchUpInside];

	UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ block, removeButton ]];
	column.axis = UILayoutConstraintAxisVertical;
	column.spacing = 4.0;
	return column;
}

#pragma mark - 冻结提示

- (UIView *)frozenBannerView {
	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.numberOfLines = 0;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textColor = UIColor.labelColor;
	label.text = @"已冻结：这台虚拟机的存放目录不在了（外接盘拔出或目录被删）。"
				  @"把目录恢复回来，它会自动解冻。";

	UIView *banner = [[UIView alloc] init];
	banner.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.15];
	banner.layer.cornerRadius = 12.0;
	[banner addSubview:label];

	[NSLayoutConstraint activateConstraints:@[
		[label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
		[label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
		[label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
		[label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0],
	]];

	return banner;
}

#pragma mark - 虚拟机状态

- (BOOL)isMachineActive {
	VLVirtualMachineState state =
		self.virtualMachine != nil ? self.virtualMachine.state : VLVirtualMachineStateStopped;
	return state == VLVirtualMachineStateStarting || state == VLVirtualMachineStateRunning;
}

- (NSString *)machineStatusText {
	NSString *message = self.virtualMachine.statusMessage;
	return message.length > 0 ? message : @"未运行";
}

/// 画面区：复用同一个 VLDisplayView，重建界面时不会丢掉最后一帧。
- (UIView *)displayAreaView {
	VLDisplayView *display = self.displayView;
	if (display == nil) {
		display = [[VLDisplayView alloc] init];
		self.displayView = display;
	}
	// 有画面时状态文字会盖在图上，只在没画面时更新。
	if (!display.hasFrame) {
		display.statusText = [self machineStatusText];
	}

	__weak typeof(self) weakSelf = self;
	display.touchHandler = ^(VLDisplayTouchPhase phase, CGFloat x, CGFloat y) {
		typeof(self) strongSelf = weakSelf;
		VLLinuxVirtualMachine *machine = strongSelf.virtualMachine;
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

	UIView *container = [[UIView alloc] init];
	container.translatesAutoresizingMaskIntoConstraints = NO;
	display.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:display];

	// 「键盘」按钮浮在画面右下角：点一下弹出系统键盘，敲的字送进客户机。
	UIButton *keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
	keyboardButton.translatesAutoresizingMaskIntoConstraints = NO;
	[keyboardButton setTitle:@"键盘" forState:UIControlStateNormal];
	keyboardButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	[keyboardButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
	keyboardButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
	keyboardButton.layer.cornerRadius = 8.0;
	[keyboardButton addTarget:self action:@selector(keyboardButtonTapped) forControlEvents:UIControlEventTouchUpInside];
	[container addSubview:keyboardButton];

	[NSLayoutConstraint activateConstraints:@[
		[display.topAnchor constraintEqualToAnchor:container.topAnchor],
		[display.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
		[display.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
		[display.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
		[container.heightAnchor constraintEqualToAnchor:container.widthAnchor multiplier:0.75],
		[keyboardButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],
		[keyboardButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
		[keyboardButton.widthAnchor constraintEqualToConstant:64.0],
		[keyboardButton.heightAnchor constraintEqualToConstant:32.0],
	]];
	return container;
}

#pragma mark - 键盘输入

- (UITextField *)keyboardField {
	if (_keyboardField == nil) {
		UITextField *field = [[UITextField alloc] init];
		field.delegate = self;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.spellCheckingType = UITextSpellCheckingTypeNo;
		field.keyboardType = UIKeyboardTypeASCIICapable;
		field.inputAccessoryView = [self keyboardAccessoryView];
		// 必须留在视图层级里才能成为第一响应者，但不要被看见。
		field.frame = CGRectMake(0.0, 0.0, 1.0, 1.0);
		field.alpha = 0.01;
		field.text = @"";
		[self.view addSubview:field];
		_keyboardField = field;
	}
	return _keyboardField;
}

- (UIView *)keyboardAccessoryView {
	UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, 0.0, 44.0)];
	NSArray<NSArray *> *specs = @[
		@[ @"Esc", @1 ], @[ @"Tab", @15 ],
		@[ @"←", @105 ], @[ @"↑", @103 ], @[ @"↓", @108 ], @[ @"→", @106 ],
		@[ @"回车", @28 ],
	];
	NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
	for (NSArray *spec in specs) {
		UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:spec[0]
																 style:UIBarButtonItemStylePlain
																target:self
																action:@selector(accessoryKeyTapped:)];
		item.tag = [spec[1] integerValue];
		[items addObject:item];
	}
	toolbar.items = items;
	[toolbar sizeToFit];
	return toolbar;
}

- (void)keyboardButtonTapped {
	[self.keyboardField becomeFirstResponder];
}

- (void)accessoryKeyTapped:(UIBarButtonItem *)sender {
	[self sendKeycode:(uint16_t)sender.tag];
	// 按完工具条按钮键盘会想收起，这里把焦点抢回来。
	[self.keyboardField becomeFirstResponder];
}

- (void)sendKeycode:(uint16_t)keycode {
	if (keycode == 0) {
		return;
	}
	VLLinuxVirtualMachine *machine = self.virtualMachine;
	[machine sendKeycode:keycode pressed:YES];
	[machine sendKeycode:keycode pressed:NO];
}

- (void)sendCharacter:(unichar)character {
	BOOL needsShift = NO;
	uint16_t keycode = VLKeycodeForCharacter(character, &needsShift);
	if (keycode == 0) {
		return;
	}
	VLLinuxVirtualMachine *machine = self.virtualMachine;
	if (needsShift) {
		[machine sendKeycode:42 pressed:YES];
	}
	[machine sendKeycode:keycode pressed:YES];
	[machine sendKeycode:keycode pressed:NO];
	if (needsShift) {
		[machine sendKeycode:42 pressed:NO];
	}
}

- (BOOL)textField:(UITextField *)textField
	shouldChangeCharactersInRange:(NSRange)range
				replacementString:(NSString *)string {
	if (textField != _keyboardField) {
		return YES;
	}
	if (string.length == 0) {
		// 系统键盘的退格键表现为「替换成空串」。
		[self sendKeycode:14];
		return NO;
	}
	for (NSUInteger index = 0; index < string.length; index++) {
		[self sendCharacter:[string characterAtIndex:index]];
	}
	// 输入框只当管道用，不留文字。
	textField.text = @"";
	return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	if (textField != _keyboardField) {
		return YES;
	}
	[self sendKeycode:28];
	textField.text = @"";
	return NO;
}

#pragma mark - 启动

- (void)startTapped {
	if ([self isMachineActive]) {
		[self.virtualMachine stop];
		self.statusLabel.text = @"正在停止…";
		return;
	}

	if (!self.configuration.isStorageAvailable) {
		[self presentMessage:@"存储不可用"
					  detail:@"虚拟机已冻结：存放目录不在了（外接盘拔出或目录被删）。恢复目录后才能启动。"];
		return;
	}

	// 每次启动都允许重新弹全屏（上次是用户自己退出的）。
	self.fullScreenSuppressedByUser = NO;

	if (self.virtualMachine == nil) {
		self.virtualMachine = [[VLLinuxVirtualMachine alloc] initWithConfiguration:self.configuration];
		self.virtualMachine.delegate = self;
	}

	NSError *error = nil;
	if (![self.virtualMachine startWithError:&error]) {
		[VLStartupLog log:@"启动被拒绝：%@（错误码 %ld）", error.localizedDescription, (long)error.code];
		self.statusLabel.text = [NSString stringWithFormat:@"启动被拒绝（错误码 %ld）：%@",
								 (long)error.code, error.localizedDescription];
		[self presentMessage:@"启动被拒绝"
					  detail:[NSString stringWithFormat:@"%@（错误码 %ld）\n\n详细信息在日志里：\n%@",
							  error.localizedDescription, (long)error.code, [VLLog logFilePath]]];
		return;
	}

	[self rebuildContent];
	[self presentFullScreenIfPossible];
}

/// 启动后直接把虚拟机画面盖满整屏，和 Virtual Mac 一样不再停在设置页。
- (void)presentFullScreenIfPossible {
	if (self.virtualMachine == nil || self.presentedViewController != nil) {
		return;
	}
	if (self.fullScreenSuppressedByUser) {
		return;
	}

	VLFullScreenViewController *controller =
		[[VLFullScreenViewController alloc] initWithMachine:self.virtualMachine];
	__weak typeof(self) weakSelf = self;
	controller.keyboardRequestHandler = ^{
		[weakSelf keyboardButtonTapped];
	};
	// 用户按「退出全屏」：记住这个选择，之后状态再变化也别把画面盖回去。
	controller.dismissHandler = ^{
		weakSelf.fullScreenController = nil;
		weakSelf.fullScreenSuppressedByUser = YES;
	};
	[controller updateStatus:[self machineStatusText]];
	self.fullScreenController = controller;
	[self presentViewController:controller animated:YES completion:nil];
}

- (void)presentMessage:(NSString *)title detail:(NSString *)detail {
	// 已经有提示在显示就不重复弹，免得两个弹窗叠在一起。
	if ([self.presentedViewController isKindOfClass:UIAlertController.class]) {
		return;
	}

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
																  message:detail
														   preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"知道了"
											  style:UIAlertActionStyleDefault
											handler:nil]];
	// 从当前最上层的界面弹，全屏盖着也看得见。
	UIViewController *target = self.presentedViewController ?: self;
	[target presentViewController:alert animated:YES completion:nil];
}

#pragma mark - VLLinuxVirtualMachineDelegate

- (void)virtualMachine:(VLLinuxVirtualMachine *)machine
	   didChangeState:(VLVirtualMachineState)state
			   message:(NSString *)message {
	if (machine != self.virtualMachine) {
		return;
	}
	if (state == VLVirtualMachineStateStopped || state == VLVirtualMachineStateFailed) {
		[self.displayView clearFrame];
		[self.fullScreenController clearFrame];
	}
	if (state == VLVirtualMachineStateStopped) {
		// 停机了就没必要一直占着整屏，退回设置页。
		[self dismissFullScreenAnimated];
	}
	if (state == VLVirtualMachineStateRunning) {
		[self presentFullScreenIfPossible];
	}
	[self.fullScreenController updateStatus:[self machineStatusText]];
	[self rebuildContent];

	if (state == VLVirtualMachineStateFailed) {
		// 后台线程起不来时不会再抛异常，只会走到这里：必须给个可见的提示，不能一闪而过。
		[self dismissFullScreenAndAlert:[NSString stringWithFormat:@"虚拟机启动失败\n\n%@", message ?: @"未知原因"]];
	}
}

- (void)dismissFullScreenAnimated {
	VLFullScreenViewController *controller = self.fullScreenController;
	self.fullScreenController = nil;
	if (controller != nil && controller.presentingViewController != nil) {
		[controller dismissViewControllerAnimated:YES completion:nil];
	}
}

- (void)dismissFullScreenAndAlert:(NSString *)detail {
	VLFullScreenViewController *controller = self.fullScreenController;
	self.fullScreenController = nil;

	NSString *message = [detail stringByAppendingFormat:@"\n\n日志：\n%@", [VLLog logFilePath]];
	void (^showAlert)(void) = ^{
		// 挪到下一个 runloop：等转场结束再弹，弹窗才不会被系统吞掉。
		dispatch_async(dispatch_get_main_queue(), ^{
			[self presentMessage:@"虚拟机启动失败" detail:message];
		});
	};

	if (controller != nil && controller.presentingViewController != nil) {
		[controller dismissViewControllerAnimated:YES completion:showAlert];
	} else if (controller != nil) {
		// 全屏还在呈现途中：等它落定再关，否则 dismiss 空转、弹窗也弹不出来。
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			[controller dismissViewControllerAnimated:NO completion:showAlert];
		});
	} else {
		showAlert();
	}
}

- (void)virtualMachine:(VLLinuxVirtualMachine *)machine
	didUpdateFrameWidth:(uint32_t)width
				 height:(uint32_t)height
				   data:(NSData *)data {
	if (machine != self.virtualMachine) {
		return;
	}
	if (self.displayView.superview == nil) {
		[self rebuildContent];
	}
	[self.displayView updateWithWidth:width height:height frame:data];
	[self.fullScreenController updateFrameWidth:width height:height data:data];
}

- (void)virtualMachine:(VLLinuxVirtualMachine *)machine didOutputLine:(NSString *)line {
	if (machine != self.virtualMachine) {
		return;
	}
	NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
	if (trimmed.length == 0 || self.statusLabel == nil) {
		return;
	}
	self.statusLabel.text = [NSString stringWithFormat:@"控制台：%@", trimmed];
}

@end
