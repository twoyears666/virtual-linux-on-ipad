#import "VLDetailViewController.h"

#import <math.h>

#import "VLDashedPlaceholderView.h"
#import "VLHostCapabilities.h"
#import "VLLinuxVirtualMachine.h"
#import "VLStartupLog.h"

@interface VLDetailViewController ()

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UILabel *cpuValueLabel;
@property (nonatomic, strong) UILabel *memoryValueLabel;
@property (nonatomic, strong) NSMutableArray<UILabel *> *diskValueLabels;
@property (nonatomic, strong) UIButton *resolutionButton;
@property (nonatomic, strong) UILabel *statusLabel;

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
	_configuration = configuration;
	self.title = configuration != nil ? configuration.name : @"虚拟机";

	if (self.isViewLoaded) {
		[self rebuildContent];
	}
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

	// 截图占位：不是必须的图，先画虚线框标注清楚位置；点按即启动。
	VLDashedPlaceholderView *placeholder = [[VLDashedPlaceholderView alloc] init];
	placeholder.translatesAutoresizingMaskIntoConstraints = NO;
	placeholder.text = [NSString stringWithFormat:@"虚拟机截图\n运行后在此显示 %@ 的客户机画面", configuration.resolutionString];
	__weak typeof(self) weakSelf = self;
	placeholder.onTap = ^{
		[weakSelf startTapped];
	};
	[placeholder.heightAnchor constraintEqualToConstant:220.0].active = YES;
	[self.stackView addArrangedSubview:placeholder];
	[VLStartupLog log:@"详情界面 截图占位完成"];

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

	// 硬件
	self.cpuValueLabel = [self valueLabelWithText:[NSString stringWithFormat:@"%lu 核", (unsigned long)configuration.cpuCores]];
	UISlider *cpuSlider = [self sliderWithMin:1.0
										  max:8.0
										value:(CGFloat)configuration.cpuCores
									   action:@selector(cpuSliderChanged:)];

	self.memoryValueLabel =
		[self valueLabelWithText:[NSString stringWithFormat:@"%lu MB", (unsigned long)configuration.memoryMB]];
	UISlider *memorySlider = [self sliderWithMin:512.0
											 max:8192.0
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

	UIButton *addDiskButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[addDiskButton setTitle:@"＋ 添加磁盘" forState:UIControlStateNormal];
	addDiskButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	[addDiskButton addTarget:self action:@selector(addDiskTapped) forControlEvents:UIControlEventTouchUpInside];
	[storageRows addObject:addDiskButton];

	UILabel *diskNote = [[UILabel alloc] init];
	diskNote.text = @"每块盘是独立镜像，首次启动前容量随意改；镜像创建后改容量会新建镜像，原数据不保留";
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

	[self.stackView addArrangedSubview:[self cardWithTitle:@"显示" rows:@[
		[self rowWithTitle:@"分辨率" control:self.resolutionButton],
		[self blockRowWithTitle:@"缩放" control:scale valueLabel:nil],
		[self rowWithTitle:@"显示设备" control:[self valueLabelWithText:@"virtio-gpu"]],
	]]];
	[VLStartupLog log:@"详情界面 显示卡片完成"];

	// 网络
	UISegmentedControl *network =
		[self segmentedControlWithTitles:@[ @"共享", @"桥接", @"无" ]
								selected:(NSInteger)configuration.networkMode
								  action:@selector(networkModeChanged:)];
	[self.stackView addArrangedSubview:[self cardWithTitle:@"网络" rows:@[
		[self blockRowWithTitle:@"网络模式" control:network valueLabel:nil],
		[self rowWithTitle:@"MAC 地址" control:[self textFieldWithPlaceholder:@"52:54:00:12:34:56"
																	   text:configuration.macAddress
																	 action:@selector(macAddressChanged:)]],
		[self rowWithTitle:@"端口转发" control:[self valueLabelWithText:@"尚未添加"]],
	]]];
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

	// 启动
	UIButton *startButton = [UIButton buttonWithType:UIButtonTypeSystem];
	startButton.translatesAutoresizingMaskIntoConstraints = NO;
	[startButton setTitle:@"启动虚拟机" forState:UIControlStateNormal];
	startButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
	[startButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	startButton.backgroundColor = self.view.tintColor;
	startButton.layer.cornerRadius = 12.0;
	[startButton addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
	[startButton.heightAnchor constraintEqualToConstant:50.0].active = YES;
	[self.stackView addArrangedSubview:startButton];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.statusLabel.textColor = UIColor.secondaryLabelColor;
	self.statusLabel.text = @"阶段：界面已就绪，虚拟化后端待接入";
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

	UIView *block = [self blockRowWithTitle:disk.name control:slider valueLabel:valueLabel];
	if (index == 0) {
		// 第一块是系统盘，不允许删除。
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

#pragma mark - 启动

- (void)startTapped {
	VLLinuxVirtualMachine *machine = [[VLLinuxVirtualMachine alloc] init];
	machine.kernelPath = self.configuration.kernelPath;
	machine.initrdPath = self.configuration.initrdPath;
	machine.memorySizeInMegabytes = self.configuration.memoryMB;

	NSError *error = nil;
	if ([machine startWithError:&error]) {
		self.statusLabel.text = @"阶段：客户机启动中";
		return;
	}

	self.statusLabel.text = [NSString stringWithFormat:@"启动被拒绝（错误码 %ld）：%@",
							 (long)error.code, error.localizedDescription];
}

@end
