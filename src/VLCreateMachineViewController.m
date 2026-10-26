#import "VLCreateMachineViewController.h"

#import <math.h>

#import "VLStartupLog.h"
#import "VLVMConfiguration.h"

@interface VLCreateMachineViewController ()

@property (nonatomic, copy) NSString *suggestedName;

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UISlider *cpuSlider;
@property (nonatomic, strong) UILabel *cpuValueLabel;
@property (nonatomic, strong) UISlider *memorySlider;
@property (nonatomic, strong) UILabel *memoryValueLabel;
@property (nonatomic, strong) UISlider *diskSlider;
@property (nonatomic, strong) UILabel *diskValueLabel;

@end

@implementation VLCreateMachineViewController

- (instancetype)initWithSuggestedName:(NSString *)suggestedName {
	self = [super initWithNibName:nil bundle:nil];
	if (self) {
		_suggestedName = [suggestedName copy];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = @"新建虚拟机";
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

	self.navigationItem.leftBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
													  target:self
													  action:@selector(cancelTapped)];
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(createTapped)];

	UIScrollView *scrollView = [[UIScrollView alloc] init];
	scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	scrollView.alwaysBounceVertical = YES;
	scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	[self.view addSubview:scrollView];

	UIStackView *stackView = [[UIStackView alloc] init];
	stackView.translatesAutoresizingMaskIntoConstraints = NO;
	stackView.axis = UILayoutConstraintAxisVertical;
	stackView.spacing = 16.0;
	[scrollView addSubview:stackView];

	[NSLayoutConstraint activateConstraints:@[
		[scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
		[scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16.0],
		[stackView.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
		[stackView.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
		[stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24.0],
	]];

	// 基本信息
	self.nameField = [[UITextField alloc] init];
	self.nameField.text = self.suggestedName;
	self.nameField.textAlignment = NSTextAlignmentRight;
	self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
	self.nameField.returnKeyType = UIReturnKeyDone;
	[self.nameField addTarget:self action:@selector(nameFieldChanged:) forControlEvents:UIControlEventEditingChanged];

	[stackView addArrangedSubview:[self cardWithTitle:@"基本信息" rows:@[
		[self rowWithTitle:@"名称" control:self.nameField],
	]]];

	// 硬件：CPU 与内存只是启动参数，创建后仍可在详情页调整
	self.cpuValueLabel = [self valueLabelWithText:@"4 核"];
	self.cpuSlider = [self sliderWithMin:1.0 max:8.0 value:4.0 action:@selector(cpuSliderChanged:)];

	self.memoryValueLabel = [self valueLabelWithText:@"2048 MB"];
	self.memorySlider = [self sliderWithMin:512.0 max:8192.0 value:2048.0 action:@selector(memorySliderChanged:)];

	[stackView addArrangedSubview:[self cardWithTitle:@"硬件" rows:@[
		[self blockRowWithTitle:@"CPU 核心数" slider:self.cpuSlider valueLabel:self.cpuValueLabel],
		[self blockRowWithTitle:@"内存" slider:self.memorySlider valueLabel:self.memoryValueLabel],
	]]];

	// 存储：创建时给出初始容量，之后仍可在详情页改
	self.diskValueLabel = [self valueLabelWithText:@"16 GB"];
	self.diskSlider = [self sliderWithMin:4.0 max:64.0 value:16.0 action:@selector(diskSliderChanged:)];

	UILabel *diskNote = [[UILabel alloc] init];
	diskNote.text = @"创建后仍可在详情页调整；镜像首次创建前改动才生效";
	diskNote.numberOfLines = 0;
	diskNote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	diskNote.textColor = UIColor.secondaryLabelColor;

	[stackView addArrangedSubview:[self cardWithTitle:@"存储" rows:@[
		[self blockRowWithTitle:@"磁盘容量" slider:self.diskSlider valueLabel:self.diskValueLabel],
		diskNote,
	]]];

	[VLStartupLog log:@"新建弹窗已加载"];
}

#pragma mark - 动作

- (void)nameFieldChanged:(UITextField *)sender {
	self.navigationItem.rightBarButtonItem.enabled = sender.text.length > 0;
}

- (void)cancelTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)createTapped {
	NSString *name = self.nameField.text.length > 0 ? self.nameField.text : self.suggestedName;
	VLVMConfiguration *configuration =
		[VLVMConfiguration sampleConfigurationWithName:name
											  memoryMB:(NSUInteger)self.memorySlider.value
												diskGB:(NSUInteger)self.diskSlider.value];
	configuration.cpuCores = (NSUInteger)self.cpuSlider.value;

	[VLStartupLog log:@"新建虚拟机：%@ %lu 核 · %lu MB · %lu GB",
					  configuration.name,
					  (unsigned long)configuration.cpuCores,
					  (unsigned long)configuration.memoryMB,
					  (unsigned long)configuration.diskGB];

	if (self.completion) {
		self.completion(configuration);
	}
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cpuSliderChanged:(UISlider *)sender {
	sender.value = roundf(sender.value);
	self.cpuValueLabel.text = [NSString stringWithFormat:@"%lu 核", (unsigned long)sender.value];
}

- (void)memorySliderChanged:(UISlider *)sender {
	sender.value = roundf(sender.value / 512.0) * 512.0;
	self.memoryValueLabel.text = [NSString stringWithFormat:@"%lu MB", (unsigned long)sender.value];
}

- (void)diskSliderChanged:(UISlider *)sender {
	sender.value = roundf(sender.value / 4.0) * 4.0;
	self.diskValueLabel.text = [NSString stringWithFormat:@"%lu GB", (unsigned long)sender.value];
}

#pragma mark - 控件构造

- (UILabel *)valueLabelWithText:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	label.textColor = UIColor.secondaryLabelColor;
	label.textAlignment = NSTextAlignmentRight;
	return label;
}

- (UISlider *)sliderWithMin:(CGFloat)minimum
						max:(CGFloat)maximum
					  value:(CGFloat)value
					 action:(SEL)action {
	UISlider *slider = [[UISlider alloc] init];
	slider.minimumValue = minimum;
	slider.maximumValue = maximum;
	slider.value = value;
	[slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
	return slider;
}

- (UIView *)rowWithTitle:(NSString *)title control:(UIView *)control {
	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
		[self titleLabelWithText:title],
		control,
	]];
	row.axis = UILayoutConstraintAxisHorizontal;
	row.spacing = 12.0;
	row.alignment = UIStackViewAlignmentCenter;
	[control setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	return row;
}

- (UIView *)blockRowWithTitle:(NSString *)title slider:(UISlider *)slider valueLabel:(UILabel *)valueLabel {
	UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[
		[self titleLabelWithText:title],
		valueLabel,
	]];
	header.axis = UILayoutConstraintAxisHorizontal;
	header.spacing = 12.0;
	header.alignment = UIStackViewAlignmentCenter;

	UIStackView *block = [[UIStackView alloc] initWithArrangedSubviews:@[ header, slider ]];
	block.axis = UILayoutConstraintAxisVertical;
	block.spacing = 6.0;
	return block;
}

- (UILabel *)titleLabelWithText:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	label.textColor = UIColor.labelColor;
	[label setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
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
	[inner addArrangedSubview:[self sectionTitleLabelWithText:title]];
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

- (UILabel *)sectionTitleLabelWithText:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	label.textColor = UIColor.labelColor;
	return label;
}

@end