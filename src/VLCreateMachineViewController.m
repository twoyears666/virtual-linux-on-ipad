#import "VLCreateMachineViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>
#import <unistd.h>

#import "VLDistroIcon.h"
#import "VLStartupLog.h"
#import "VLVMConfiguration.h"

@interface VLCreateMachineViewController () <UIDocumentPickerDelegate>

@property (nonatomic, copy) NSString *suggestedName;
@property (nonatomic, copy) NSString *selectedDistro;
@property (nonatomic, strong) NSMutableArray<UIButton *> *distroButtons;
@property (nonatomic, strong) UILabel *distroNameLabel;

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UISlider *cpuSlider;
@property (nonatomic, strong) UILabel *cpuValueLabel;
@property (nonatomic, strong) UISlider *memorySlider;
@property (nonatomic, strong) UILabel *memoryValueLabel;
@property (nonatomic, strong) UISlider *diskSlider;
@property (nonatomic, strong) UILabel *diskValueLabel;

@property (nonatomic, strong) NSURL *isoURL;
@property (nonatomic, strong) UILabel *isoLabel;

@property (nonatomic, strong) UIView *provisioningOverlay;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;

@end

@implementation VLCreateMachineViewController

- (instancetype)initWithSuggestedName:(NSString *)suggestedName {
	self = [super initWithNibName:nil bundle:nil];
	if (self) {
		_suggestedName = [suggestedName copy];
		_selectedDistro = @"linux";
		_distroButtons = [NSMutableArray array];
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

	[stackView addArrangedSubview:[self distroCard]];
	[stackView addArrangedSubview:[self basicInfoCard]];
	[stackView addArrangedSubview:[self hardwareCard]];
	[stackView addArrangedSubview:[self storageCard]];
	[stackView addArrangedSubview:[self isoCard]];

	[self updateDistroSelection];
	[self updateDoneState];
	[VLStartupLog log:@"新建弹窗已加载"];
}

#pragma mark - 卡片

- (UIView *)distroCard {
	UIStackView *iconRow = [[UIStackView alloc] init];
	iconRow.axis = UILayoutConstraintAxisHorizontal;
	iconRow.spacing = 12.0;
	iconRow.distribution = UIStackViewDistributionFillEqually;
	iconRow.alignment = UIStackViewAlignmentCenter;

	NSArray<NSString *> *identifiers = [VLDistroIcon allIdentifiers];
	for (NSUInteger index = 0; index < identifiers.count; index++) {
		NSString *identifier = identifiers[index];
		UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
		button.tag = (NSInteger)index;
		button.layer.cornerRadius = 14.0;
		button.layer.borderWidth = 2.0;
		button.layer.borderColor = UIColor.clearColor.CGColor;
		button.backgroundColor = [[VLDistroIcon colorForIdentifier:identifier] colorWithAlphaComponent:0.14];
		button.tintColor = [VLDistroIcon colorForIdentifier:identifier];
		[button setImage:[UIImage systemImageNamed:[VLDistroIcon symbolNameForIdentifier:identifier]
															  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24.0
																															  weight:UIImageSymbolWeightSemibold]]
				forState:UIControlStateNormal];
		[button.heightAnchor constraintEqualToConstant:52.0].active = YES;
		[button addTarget:self action:@selector(distroTapped:) forControlEvents:UIControlEventTouchUpInside];
		[self.distroButtons addObject:button];
		[iconRow addArrangedSubview:button];
	}

	self.distroNameLabel = [[UILabel alloc] init];
	self.distroNameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.distroNameLabel.textColor = UIColor.secondaryLabelColor;
	self.distroNameLabel.textAlignment = NSTextAlignmentCenter;

	UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ iconRow, self.distroNameLabel ]];
	column.axis = UILayoutConstraintAxisVertical;
	column.spacing = 8.0;

	return [self cardWithTitle:@"发行版图标" rows:@[ column ]];
}

- (UIView *)basicInfoCard {
	self.nameField = [[UITextField alloc] init];
	self.nameField.text = self.suggestedName;
	self.nameField.textAlignment = NSTextAlignmentRight;
	self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
	self.nameField.returnKeyType = UIReturnKeyDone;
	[self.nameField addTarget:self action:@selector(nameFieldChanged:) forControlEvents:UIControlEventEditingChanged];

	return [self cardWithTitle:@"基本信息" rows:@[
		[self rowWithTitle:@"名称" control:self.nameField],
	]];
}

- (UIView *)hardwareCard {
	self.cpuValueLabel = [self valueLabelWithText:@"4 核"];
	self.cpuSlider = [self sliderWithMin:1.0 max:8.0 value:4.0 action:@selector(cpuSliderChanged:)];

	self.memoryValueLabel = [self valueLabelWithText:@"2048 MB"];
	self.memorySlider = [self sliderWithMin:512.0 max:8192.0 value:2048.0 action:@selector(memorySliderChanged:)];

	return [self cardWithTitle:@"硬件" rows:@[
		[self blockRowWithTitle:@"CPU 核心数" slider:self.cpuSlider valueLabel:self.cpuValueLabel],
		[self blockRowWithTitle:@"内存" slider:self.memorySlider valueLabel:self.memoryValueLabel],
	]];
}

- (UIView *)storageCard {
	self.diskValueLabel = [self valueLabelWithText:@"16 GB"];
	self.diskSlider = [self sliderWithMin:4.0 max:64.0 value:16.0 action:@selector(diskSliderChanged:)];

	UILabel *note = [[UILabel alloc] init];
	note.text = @"这是系统盘容量，创建后可在详情页添加更多磁盘";
	note.numberOfLines = 0;
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.secondaryLabelColor;

	return [self cardWithTitle:@"存储" rows:@[
		[self blockRowWithTitle:@"系统盘容量" slider:self.diskSlider valueLabel:self.diskValueLabel],
		note,
	]];
}

- (UIView *)isoCard {
	UIButton *importButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[importButton setTitle:@"导入 ISO 安装镜像" forState:UIControlStateNormal];
	importButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	importButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
	[importButton addTarget:self action:@selector(importIsoTapped) forControlEvents:UIControlEventTouchUpInside];

	self.isoLabel = [[UILabel alloc] init];
	self.isoLabel.text = @"未选择（必需）";
	self.isoLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.isoLabel.textColor = UIColor.secondaryLabelColor;
	self.isoLabel.numberOfLines = 0;

	UILabel *note = [[UILabel alloc] init];
	note.text = @"点完成后会先把 ISO 与磁盘镜像准备好，全部完成才回到主界面";
	note.numberOfLines = 0;
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.secondaryLabelColor;

	return [self cardWithTitle:@"安装镜像" rows:@[ importButton, self.isoLabel, note ]];
}

#pragma mark - 动作

- (void)distroTapped:(UIButton *)sender {
	NSArray<NSString *> *identifiers = [VLDistroIcon allIdentifiers];
	NSInteger index = sender.tag;
	if (index < 0 || index >= (NSInteger)identifiers.count) {
		return;
	}
	self.selectedDistro = identifiers[(NSUInteger)index];
	[self updateDistroSelection];
}

- (void)updateDistroSelection {
	NSArray<NSString *> *identifiers = [VLDistroIcon allIdentifiers];
	NSUInteger selectedIndex = [identifiers indexOfObject:self.selectedDistro];

	for (NSUInteger index = 0; index < self.distroButtons.count; index++) {
		UIButton *button = self.distroButtons[index];
		BOOL selected = index == selectedIndex;
		button.layer.borderColor = selected ? [VLDistroIcon colorForIdentifier:identifiers[index]].CGColor
										   : UIColor.clearColor.CGColor;
	}
	self.distroNameLabel.text =
		[NSString stringWithFormat:@"已选：%@", [VLDistroIcon displayNameForIdentifier:self.selectedDistro]];
}

- (void)nameFieldChanged:(UITextField *)sender {
	[self updateDoneState];
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

- (void)updateDoneState {
	self.navigationItem.rightBarButtonItem.enabled = self.nameField.text.length > 0 && self.isoURL != nil;
}

- (void)importIsoTapped {
	NSMutableArray<UTType *> *types = [NSMutableArray array];
	UTType *isoType = [UTType typeWithFilenameExtension:@"iso"];
	UTType *imgType = [UTType typeWithFilenameExtension:@"img"];
	if (isoType != nil) {
		[types addObject:isoType];
	}
	if (imgType != nil) {
		[types addObject:imgType];
	}
	if (types.count == 0) {
		[types addObject:UTTypeData];
	}

	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (url == nil) {
		return;
	}
	self.isoURL = url;
	self.isoLabel.text = url.lastPathComponent;
	self.isoLabel.textColor = UIColor.labelColor;
	[VLStartupLog log:@"已选择 ISO：%@", url.lastPathComponent];
	[self updateDoneState];
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
	configuration.distroIdentifier = self.selectedDistro;

	[self setFormBusy:YES];
	[VLStartupLog log:@"置备开始：%@ · %@", configuration.name,
					  [VLDistroIcon displayNameForIdentifier:configuration.distroIdentifier]];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError *error = nil;
		BOOL prepared = [self prepareStorageForConfiguration:configuration error:&error];

		dispatch_async(dispatch_get_main_queue(), ^{
			if (!prepared) {
				[VLStartupLog log:@"置备失败：%@", error.localizedDescription];
				[self setFormBusy:NO];
				UIAlertController *alert =
					[UIAlertController alertControllerWithTitle:@"准备工作失败"
														message:error.localizedDescription
												 preferredStyle:UIAlertControllerStyleAlert];
				[alert addAction:[UIAlertAction actionWithTitle:@"好"
														  style:UIAlertActionStyleDefault
														handler:nil]];
				[self presentViewController:alert animated:YES completion:nil];
				return;
			}

			[VLStartupLog log:@"置备完成，返回主界面"];
			if (self.completion) {
				self.completion(configuration);
			}
			[self dismissViewControllerAnimated:YES completion:nil];
		});
	});
}

#pragma mark - 置备

/// 把 ISO 拷进沙盒、按容量创建空白（稀疏）磁盘镜像。全部成功才返回 YES。
- (BOOL)prepareStorageForConfiguration:(VLVMConfiguration *)configuration error:(NSError **)error {
	NSFileManager *fileManager = NSFileManager.defaultManager;

	[self reportProgress:0.10 status:@"创建虚拟机目录…"];

	NSURL *documents = [fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
	NSURL *machineDirectory = [[documents URLByAppendingPathComponent:@"VirtualMachines" isDirectory:YES]
		URLByAppendingPathComponent:NSUUID.UUID.UUIDString
					  isDirectory:YES];
	if (![fileManager createDirectoryAtURL:machineDirectory
			   withIntermediateDirectories:YES
								attributes:nil
									 error:error]) {
		return NO;
	}

	[self reportProgress:0.30 status:@"拷贝 ISO 安装镜像…"];
	NSURL *isoDestination = [machineDirectory URLByAppendingPathComponent:@"install.iso"];
	if ([fileManager fileExistsAtPath:isoDestination.path]) {
		[fileManager removeItemAtURL:isoDestination error:nil];
	}
	if (![fileManager copyItemAtURL:self.isoURL toURL:isoDestination error:error]) {
		return NO;
	}
	configuration.isoPath = isoDestination.path;

	NSURL *disksDirectory = [machineDirectory URLByAppendingPathComponent:@"disks" isDirectory:YES];
	if (![fileManager createDirectoryAtURL:disksDirectory
			   withIntermediateDirectories:YES
								attributes:nil
									 error:error]) {
		return NO;
	}

	NSUInteger diskCount = configuration.disks.count;
	for (NSUInteger index = 0; index < diskCount; index++) {
		VLDiskImage *disk = configuration.disks[index];
		[self reportProgress:0.30 + 0.6 * ((CGFloat)(index + 1) / (CGFloat)diskCount)
					 status:[NSString stringWithFormat:@"创建 %@ 镜像…", disk.name]];

		NSURL *imageURL = [disksDirectory URLByAppendingPathComponent:
			[NSString stringWithFormat:@"%@.img", disk.name]];
		if (![fileManager createFileAtPath:imageURL.path contents:nil attributes:nil]) {
			if (error != NULL) {
				*error = [NSError errorWithDomain:@"com.twoyears666.virtuallinux.create"
											 code:1
										 userInfo:@{ NSLocalizedDescriptionKey : @"无法创建磁盘镜像文件" }];
			}
			return NO;
		}

		// 稀疏文件：逻辑容量按 GB 写足，实际占用随写入增长。
		int descriptor = open(imageURL.path.fileSystemRepresentation, O_WRONLY);
		if (descriptor < 0) {
			if (error != NULL) {
				*error = [NSError errorWithDomain:@"com.twoyears666.virtuallinux.create"
											 code:2
										 userInfo:@{ NSLocalizedDescriptionKey : @"无法打开磁盘镜像文件" }];
			}
			return NO;
		}
		off_t bytes = (off_t)disk.sizeGB * 1024LL * 1024LL * 1024LL;
		int truncateResult = ftruncate(descriptor, bytes);
		close(descriptor);
		if (truncateResult != 0) {
			if (error != NULL) {
				*error = [NSError errorWithDomain:@"com.twoyears666.virtuallinux.create"
											 code:3
										 userInfo:@{ NSLocalizedDescriptionKey : @"无法分配磁盘镜像容量" }];
			}
			return NO;
		}

		disk.path = imageURL.path;
	}

	configuration.diskImageReady = YES;
	[self reportProgress:1.0 status:@"准备完成"];
	return YES;
}

- (void)reportProgress:(CGFloat)progress status:(NSString *)status {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.progressView.progress = (float)progress;
		self.progressLabel.text = status;
	});
}

#pragma mark - 置备提示层

- (void)setFormBusy:(BOOL)busy {
	self.navigationItem.leftBarButtonItem.enabled = !busy;
	self.navigationItem.rightBarButtonItem.enabled = !busy;

	if (!busy) {
		[self.provisioningOverlay removeFromSuperview];
		self.provisioningOverlay = nil;
		return;
	}

	UIView *overlay = [[UIView alloc] init];
	overlay.translatesAutoresizingMaskIntoConstraints = NO;
	overlay.backgroundColor = UIColor.systemBackgroundColor;
	[self.view addSubview:overlay];

	UIActivityIndicatorView *spinner =
		[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	spinner.translatesAutoresizingMaskIntoConstraints = NO;
	[spinner startAnimating];

	UILabel *title = [[UILabel alloc] init];
	title.translatesAutoresizingMaskIntoConstraints = NO;
	title.text = @"正在准备安装镜像与磁盘";
	title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	title.textAlignment = NSTextAlignmentCenter;

	UIProgressView *progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	progressView.translatesAutoresizingMaskIntoConstraints = NO;
	progressView.progress = 0.0f;

	UILabel *status = [[UILabel alloc] init];
	status.translatesAutoresizingMaskIntoConstraints = NO;
	status.text = @"准备中…";
	status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	status.textColor = UIColor.secondaryLabelColor;
	status.textAlignment = NSTextAlignmentCenter;
	status.numberOfLines = 0;

	UILabel *note = [[UILabel alloc] init];
	note.translatesAutoresizingMaskIntoConstraints = NO;
	note.text = @"全部完成前不会返回主界面，请不要离开";
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.tertiaryLabelColor;
	note.textAlignment = NSTextAlignmentCenter;
	note.numberOfLines = 0;

	for (UIView *view in @[ spinner, title, progressView, status, note ]) {
		[overlay addSubview:view];
	}

	[NSLayoutConstraint activateConstraints:@[
		[overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[spinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
		[spinner.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-80.0],

		[title.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:16.0],
		[title.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:32.0],
		[title.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-32.0],

		[progressView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16.0],
		[progressView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:48.0],
		[progressView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-48.0],

		[status.topAnchor constraintEqualToAnchor:progressView.bottomAnchor constant:10.0],
		[status.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:32.0],
		[status.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-32.0],

		[note.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:18.0],
		[note.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:32.0],
		[note.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-32.0],
	]];

	self.provisioningOverlay = overlay;
	self.progressView = progressView;
	self.progressLabel = status;
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