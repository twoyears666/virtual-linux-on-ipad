#import "VLCreateMachineViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>
#import <unistd.h>

#import "VLDistroIcon.h"
#import "VLHostCapabilities.h"
#import "VLISOInstaller.h"
#import "VLStartupLog.h"
#import "VLStorageManager.h"
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

/// 这次把虚拟机装到哪个已登记的存储位置。
@property (nonatomic, strong) VLStorageLocation *selectedLocation;
@property (nonatomic, strong) UIButton *storageButton;

@property (nonatomic, strong) NSURL *isoURL;
@property (nonatomic, strong) UILabel *isoLabel;

/// 用户导入的自定义图标；为空表示用发行版官方图标。
@property (nonatomic, strong) NSURL *iconURL;
@property (nonatomic, strong) UIImageView *iconPreviewView;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UIButton *customIconButton;
/// 区分当前弹的是 ISO 选择器还是图标选择器。
@property (nonatomic, assign) BOOL pickingIcon;

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
		_selectedLocation = VLStorageManager.sharedManager.defaultLocation;
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
		button.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.10];
		// 统一蓝色剪影，不显示各发行版自带配色。
		button.tintColor = UIColor.systemBlueColor;
		[button setImage:[VLDistroIcon templateThumbnailForIdentifier:identifier size:32.0]
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

	self.customIconButton = [self buildCustomIconButton];

	UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:
		@[ iconRow, self.distroNameLabel, self.customIconButton ]];
	column.axis = UILayoutConstraintAxisVertical;
	column.spacing = 10.0;

	return [self cardWithTitle:@"发行版图标" rows:@[ column ]];
}

/// 自定义图标入口：默认显示「导入自定义图标」，导入后显示缩略图与文件名。
- (UIButton *)buildCustomIconButton {
	self.iconPreviewView = [[UIImageView alloc] init];
	self.iconPreviewView.contentMode = UIViewContentModeScaleAspectFit;
	self.iconPreviewView.translatesAutoresizingMaskIntoConstraints = NO;

	self.iconLabel = [[UILabel alloc] init];
	self.iconLabel.text = @"导入自定义图标（可选）";
	self.iconLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.iconLabel.textColor = UIColor.systemBlueColor;
	self.iconLabel.numberOfLines = 1;

	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.layer.cornerRadius = 12.0;
	button.layer.borderWidth = 1.0;
	button.layer.borderColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.25].CGColor;
	button.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.08];
	[button.heightAnchor constraintEqualToConstant:44.0].active = YES;
	[button addTarget:self action:@selector(importIconTapped) forControlEvents:UIControlEventTouchUpInside];

	UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[ self.iconPreviewView, self.iconLabel ]];
	content.axis = UILayoutConstraintAxisHorizontal;
	content.spacing = 8.0;
	content.alignment = UIStackViewAlignmentCenter;
	content.userInteractionEnabled = NO;
	content.translatesAutoresizingMaskIntoConstraints = NO;
	[button addSubview:content];

	[NSLayoutConstraint activateConstraints:@[
		[content.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
		[content.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
		[content.leadingAnchor constraintGreaterThanOrEqualToAnchor:button.leadingAnchor constant:12.0],
		[content.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-12.0],
		[self.iconPreviewView.widthAnchor constraintEqualToConstant:24.0],
		[self.iconPreviewView.heightAnchor constraintEqualToConstant:24.0],
	]];

	return button;
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

	// 内存上限：本机内存的一半，并且至少给系统留 2 GB，按 512 MB 对齐。
	NSUInteger maximumMemoryMB = MAX((NSUInteger)512, [VLHostCapabilities maximumGuestMemoryMB]);
	NSUInteger defaultMemoryMB = MIN((NSUInteger)2048, maximumMemoryMB);
	self.memoryValueLabel =
		[self valueLabelWithText:[NSString stringWithFormat:@"%lu MB", (unsigned long)defaultMemoryMB]];
	self.memorySlider = [self sliderWithMin:512.0
										max:(CGFloat)maximumMemoryMB
									  value:(CGFloat)defaultMemoryMB
									 action:@selector(memorySliderChanged:)];

	UILabel *note = [[UILabel alloc] init];
	note.text = [NSString stringWithFormat:@"按 0.5 GB 递增，最大 %lu MB（本机 %lu MB 的一半，且至少给系统留 2 GB）",
				 (unsigned long)maximumMemoryMB, (unsigned long)[VLHostCapabilities physicalMemoryMB]];
	note.numberOfLines = 0;
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.secondaryLabelColor;

	return [self cardWithTitle:@"硬件" rows:@[
		[self blockRowWithTitle:@"CPU 核心数" slider:self.cpuSlider valueLabel:self.cpuValueLabel],
		[self blockRowWithTitle:@"内存" slider:self.memorySlider valueLabel:self.memoryValueLabel],
		note,
	]];
}

- (UIView *)storageCard {
	self.diskValueLabel = [self valueLabelWithText:@"16 GB"];
	self.diskSlider = [self sliderWithMin:4.0 max:64.0 value:16.0 action:@selector(diskSliderChanged:)];

	// 存放位置：默认本机存储，可切到已登记的外接目录。
	self.storageButton = [UIButton buttonWithType:UIButtonTypeSystem];
	self.storageButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	self.storageButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
	self.storageButton.showsMenuAsPrimaryAction = YES;
	[self.storageButton setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
	self.storageButton.menu = [self storageMenu];
	[self updateStorageButton];

	UILabel *note = [[UILabel alloc] init];
	note.text = @"这是系统盘容量，创建后可在详情页添加更多磁盘";
	note.numberOfLines = 0;
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.secondaryLabelColor;

	UILabel *storageNote = [[UILabel alloc] init];
	storageNote.text = @"外接目录可在设置页添加；目录丢失时该虚拟机自动冻结";
	storageNote.numberOfLines = 0;
	storageNote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	storageNote.textColor = UIColor.secondaryLabelColor;

	return [self cardWithTitle:@"存储" rows:@[
		[self rowWithTitle:@"存放位置" control:self.storageButton],
		[self blockRowWithTitle:@"系统盘容量" slider:self.diskSlider valueLabel:self.diskValueLabel],
		note,
		storageNote,
	]];
}

- (UIMenu *)storageMenu {
	NSMutableArray<UIAction *> *actions = [NSMutableArray array];
	__weak typeof(self) weakSelf = self;

	for (VLStorageLocation *location in VLStorageManager.sharedManager.locations) {
		NSString *title = location.isAvailable
			? location.name
			: [NSString stringWithFormat:@"%@（不可用）", location.name];
		UIAction *action =
			[UIAction actionWithTitle:title
								image:[UIImage systemImageNamed:location.isBuiltIn ? @"ipad" : @"externaldrive"]
						   identifier:nil
							  handler:^(UIAction *selected) {
			weakSelf.selectedLocation = location;
			[weakSelf updateStorageButton];
		}];
		action.state = [location.identifier isEqualToString:self.selectedLocation.identifier]
			? UIMenuElementStateOn
			: UIMenuElementStateOff;
		[actions addObject:action];
	}

	return [UIMenu menuWithTitle:@"" children:actions];
}

- (void)updateStorageButton {
	VLStorageLocation *location = self.selectedLocation ?: VLStorageManager.sharedManager.defaultLocation;
	NSString *title = location.isAvailable
		? location.name
		: [NSString stringWithFormat:@"%@（不可用）", location.name];
	[self.storageButton setTitle:title forState:UIControlStateNormal];
	self.storageButton.menu = [self storageMenu];
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

	// 越狱环境里系统文件选择器不一定可用，留一个直接写路径的入口兜底。
	UIButton *pathButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[pathButton setTitle:@"直接输入文件路径" forState:UIControlStateNormal];
	pathButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	pathButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
	[pathButton addTarget:self action:@selector(manualISOPathTapped) forControlEvents:UIControlEventTouchUpInside];

	UILabel *note = [[UILabel alloc] init];
	note.text = @"点完成后会先把 ISO 与磁盘镜像准备好，全部完成才回到主界面";
	note.numberOfLines = 0;
	note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	note.textColor = UIColor.secondaryLabelColor;

	return [self cardWithTitle:@"安装镜像" rows:@[ importButton, self.isoLabel, pathButton, note ]];
}

#pragma mark - 动作

- (void)distroTapped:(UIButton *)sender {
	NSArray<NSString *> *identifiers = [VLDistroIcon allIdentifiers];
	NSInteger index = sender.tag;
	if (index < 0 || index >= (NSInteger)identifiers.count) {
		return;
	}
	self.selectedDistro = identifiers[(NSUInteger)index];
	// 选了发行版图标就清除自定义图标，两者只有一个生效。
	self.iconURL = nil;
	self.iconPreviewView.image = nil;
	self.iconLabel.text = @"导入自定义图标（可选）";
	[self updateDistroSelection];
}

- (void)updateDistroSelection {
	NSArray<NSString *> *identifiers = [VLDistroIcon allIdentifiers];
	NSUInteger selectedIndex = [identifiers indexOfObject:self.selectedDistro];

	for (NSUInteger index = 0; index < self.distroButtons.count; index++) {
		UIButton *button = self.distroButtons[index];
		BOOL selected = index == selectedIndex && self.iconURL == nil;
		button.layer.borderColor = selected ? UIColor.systemBlueColor.CGColor : UIColor.clearColor.CGColor;
	}

	self.customIconButton.layer.borderColor =
		self.iconURL != nil ? UIColor.systemBlueColor.CGColor
							: [UIColor.systemBlueColor colorWithAlphaComponent:0.25].CGColor;

	NSString *distroName = [VLDistroIcon displayNameForIdentifier:self.selectedDistro];
	self.distroNameLabel.text = self.iconURL != nil
		? [NSString stringWithFormat:@"已选：%@ · 自定义图标", distroName]
		: [NSString stringWithFormat:@"已选：%@", distroName];
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
	// 不用「按扩展名造 UTType」来筛文件：.iso / .img 在 iOS 上没有系统声明的类型，
	// 动态 UTType 会让文件在选择器里「看着能点、点了没反应」。这里放开成所有文件，
	// 选完之后我们自己校验扩展名。
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ] asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	self.pickingIcon = NO;
	[VLStartupLog log:@"打开安装镜像选择器（接受所有文件，选完再校验扩展名）"];
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)importIconTapped {
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeImage ] asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	self.pickingIcon = YES;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (url == nil) {
		return;
	}

	if (self.pickingIcon) {
		UIImage *image = [UIImage imageWithContentsOfFile:url.path];
		if (image == nil) {
			[VLStartupLog log:@"自定义图标读取失败：%@", url.lastPathComponent];
			return;
		}
		self.iconURL = url;
		self.iconPreviewView.image = [VLDistroIcon thumbnailForImage:image size:24.0];
		self.iconLabel.text = url.lastPathComponent;
		[VLStartupLog log:@"已选择自定义图标：%@", url.lastPathComponent];
		[self updateDistroSelection];
		return;
	}

	NSString *extension = url.pathExtension.lowercaseString;
	if (![extension isEqualToString:@"iso"] && ![extension isEqualToString:@"img"]) {
		[VLStartupLog log:@"选中的文件不是安装镜像：%@", url.lastPathComponent];
		UIAlertController *alert =
			[UIAlertController alertControllerWithTitle:@"选的不是安装镜像"
												message:[NSString stringWithFormat:
													@"「%@」的扩展名不是 .iso 或 .img。",
													url.lastPathComponent]
										 preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"知道了"
												  style:UIAlertActionStyleDefault
												handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	NSNumber *fileSize = nil;
	[url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
	[VLStartupLog log:@"选择器回调：%@（%lld 字节）",
	 url.lastPathComponent, (long long)fileSize.longLongValue];

	self.isoURL = url;
	self.isoLabel.text = url.lastPathComponent;
	self.isoLabel.textColor = UIColor.labelColor;
	[VLStartupLog log:@"已选择 ISO：%@", url.lastPathComponent];
	[self updateDoneState];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	[VLStartupLog log:@"安装镜像选择器被取消（没有选到文件）"];
}

#pragma mark - 手动输入路径

- (void)manualISOPathTapped {
	UIAlertController *alert =
		[UIAlertController alertControllerWithTitle:@"直接输入文件路径"
											message:@"例如 /var/mobile/Media/debian-12.5.0-arm64-netinst.iso"
									 preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"/var/mobile/Media/xxx.iso";
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.text = @"/var/mobile/Media/";
	}];
	[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	__weak typeof(self) weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"使用" style:UIAlertActionStyleDefault
										   handler:^(UIAlertAction *action) {
		[weakSelf applyManualISOPath:alert.textFields.firstObject.text];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)applyManualISOPath:(NSString *)rawPath {
	NSString *path = [rawPath stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (path.length == 0) {
		return;
	}
	NSString *extension = path.pathExtension.lowercaseString;
	BOOL extensionOK = [extension isEqualToString:@"iso"] || [extension isEqualToString:@"img"];
	BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
	[VLStartupLog log:@"手动输入安装镜像：%@（存在=%d，扩展名=%@）", path, exists ? 1 : 0, extension];

	if (!exists || !extensionOK) {
		UIAlertController *alert =
			[UIAlertController alertControllerWithTitle:@"路径不对"
												message:exists
													? @"这个文件的扩展名不是 .iso 或 .img。"
													: @"这个路径上没有文件。越狱设备上 ISO 一般放在 /var/mobile/Media 下。"
										 preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	self.isoURL = [NSURL fileURLWithPath:path];
	self.isoLabel.text = path.lastPathComponent;
	self.isoLabel.textColor = UIColor.labelColor;
	[VLStartupLog log:@"已选择 ISO（手动路径）：%@", path];
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

	VLStorageLocation *location = self.selectedLocation ?: VLStorageManager.sharedManager.defaultLocation;
	if (location == nil || !location.isAvailable) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"com.twoyears666.virtuallinux.create"
										 code:4
									 userInfo:@{ NSLocalizedDescriptionKey : @"存放位置不可用，请在设置页换一个位置" }];
		}
		return NO;
	}

	NSURL *machineDirectory = [location machineDirectoryForIdentifier:NSUUID.UUID.UUIDString];
	if (![fileManager createDirectoryAtURL:machineDirectory
			   withIntermediateDirectories:YES
								attributes:nil
									 error:error]) {
		return NO;
	}

	configuration.rootPath = machineDirectory.path;
	configuration.storageIdentifier = location.identifier;

	[self reportProgress:0.20 status:@"拷贝自定义图标…"];
	if (self.iconURL != nil) {
		NSString *extension = self.iconURL.pathExtension.length > 0 ? self.iconURL.pathExtension : @"png";
		NSURL *iconDestination =
			[machineDirectory URLByAppendingPathComponent:[@"icon" stringByAppendingPathExtension:extension]];
		if (![fileManager copyItemAtURL:self.iconURL toURL:iconDestination error:error]) {
			return NO;
		}
		configuration.iconPath = iconDestination.path;
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

	// 解析 ISO：Debian 系抽出内核 + initrd 并生成 preseed，供后端直接启动安装。
	[self reportProgress:0.40 status:@"解析 ISO 并抽取内核…"];
	VLISOInstallResult *isoResult =
		[VLISOInstaller prepareISOAtPath:isoDestination.path
						machineDirectory:machineDirectory
					   distroIdentifier:configuration.distroIdentifier
								  error:NULL];
	if (isoResult != nil) {
		configuration.kernelPath = isoResult.kernelPath;
		configuration.initrdPath = isoResult.initrdPath;
		configuration.preseedPath = isoResult.preseedPath ?: @"";
		[VLStartupLog log:@"ISO 自动安装准备完成：%@", isoResult.summary];
	} else {
		// 认不出来不算失败：ISO 已拷好，等后端支持其它发行版后再补。
		[VLStartupLog log:@"ISO 未识别，跳过自动安装准备：%@", isoDestination.lastPathComponent];
	}

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
		[self reportProgress:0.45 + 0.5 * ((CGFloat)(index + 1) / (CGFloat)diskCount)
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