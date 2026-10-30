// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLSidebarViewController.h"

#import "VLCreateMachineViewController.h"
#import "VLDistroIcon.h"
#import "VLSettingsViewController.h"
#import "VLStartupLog.h"
#import "VLStorageManager.h"
#import "VLVMStore.h"

static NSString *const VLSidebarCellIdentifier = @"VLSidebarCellIdentifier";

@interface VLSidebarViewController ()

@property (nonatomic, strong) NSMutableArray<VLVMConfiguration *> *machines;

@end

@implementation VLSidebarViewController

- (instancetype)init {
	return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	[VLStartupLog log:@"侧栏 viewDidLoad 进入"];

	self.title = @"虚拟机";
	self.machines = [VLVMStore.sharedStore.machines mutableCopy];

	self.tableView.rowHeight = 64.0;
	self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

	UIBarButtonItem *addItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
													  target:self
													  action:@selector(addTapped)];
	UIBarButtonItem *settingsItem =
		[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
										 style:UIBarButtonItemStylePlain
										target:self
										action:@selector(settingsTapped)];
	// 齿轮在左，+ 在最右，符合习惯。
	self.navigationItem.rightBarButtonItems = @[ addItem, settingsItem ];

	// 存储位置增删、以及从后台切回来（可能插回了外接盘）都刷新一次冻结状态。
	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(storageDidChange)
											   name:VLStorageManager.didChangeNotification
											 object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self
										   selector:@selector(storageDidChange)
											   name:UIApplicationDidBecomeActiveNotification
											 object:nil];
}

- (void)storageDidChange {
	[self.tableView reloadData];
}

- (void)settingsTapped {
	VLSettingsViewController *settings = [[VLSettingsViewController alloc] init];
	UINavigationController *navigationController =
		[[UINavigationController alloc] initWithRootViewController:settings];
	navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
	[self presentViewController:navigationController animated:YES completion:nil];
}

- (void)selectConfigurationAtIndex:(NSUInteger)index {
	[self loadViewIfNeeded];
	if (index >= self.machines.count) {
		return;
	}

	NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
	[self.tableView selectRowAtIndexPath:indexPath
								animated:NO
						  scrollPosition:UITableViewScrollPositionNone];
}

- (void)reloadMachines {
	[self.tableView reloadData];
}

- (void)addTapped {
	NSString *suggestedName =
		[NSString stringWithFormat:@"虚拟机 %lu",
			(unsigned long)VLVMStore.sharedStore.machines.count + 1];
	VLCreateMachineViewController *creator =
		[[VLCreateMachineViewController alloc] initWithSuggestedName:suggestedName];

	__weak typeof(self) weakSelf = self;
	creator.completion = ^(VLVMConfiguration *configuration) {
		[VLVMStore.sharedStore addMachineWithConfiguration:configuration];
		weakSelf.machines = [VLVMStore.sharedStore.machines mutableCopy];
		[weakSelf.tableView reloadData];

		NSUInteger index = weakSelf.machines.count - 1;
		[weakSelf selectConfigurationAtIndex:index];
		[weakSelf.selectionDelegate sidebarViewController:weakSelf
								   didSelectConfiguration:weakSelf.machines[index]];
	};

	UINavigationController *navigationController =
		[[UINavigationController alloc] initWithRootViewController:creator];
	navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
	[self presentViewController:navigationController animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)self.machines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:VLSidebarCellIdentifier];
	if (cell == nil) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
									  reuseIdentifier:VLSidebarCellIdentifier];
	}

	VLVMConfiguration *machine = self.machines[(NSUInteger)indexPath.row];
	BOOL frozen = !machine.isStorageAvailable;
	cell.textLabel.text = machine.name;
	cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	cell.textLabel.textColor = frozen ? UIColor.secondaryLabelColor : UIColor.labelColor;
	cell.detailTextLabel.text = frozen ? @"存储不可用 · 已冻结" : machine.summary;
	cell.detailTextLabel.textColor = frozen ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
	// 自定义图标优先，没导入时才用发行版官方图标。
	UIImage *customIcon = machine.iconPath.length > 0
		? [UIImage imageWithContentsOfFile:machine.iconPath]
		: nil;
	cell.imageView.image = customIcon != nil
		? [VLDistroIcon thumbnailForImage:customIcon size:28.0]
		: [VLDistroIcon thumbnailForIdentifier:machine.distroIdentifier size:28.0];
	cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
	cell.imageView.alpha = frozen ? 0.35 : 1.0;
	cell.accessoryType = UITableViewCellAccessoryNone;

	return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[self.selectionDelegate sidebarViewController:self
						   didSelectConfiguration:self.machines[(NSUInteger)indexPath.row]];
}

#pragma mark - 左滑删除

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
	trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
	UIContextualAction *deleteAction =
		[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
												title:@"删除"
											  handler:^(UIContextualAction *action,
														UIView *sourceView,
														void (^completionHandler)(BOOL)) {
		// 先收起侧滑，再弹确认，避免弹窗和滑动动画互相打断。
		completionHandler(YES);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self confirmDeleteAtIndex:(NSUInteger)indexPath.row];
		});
	}];
	deleteAction.image = [UIImage systemImageNamed:@"trash"];
	return [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
}

- (void)confirmDeleteAtIndex:(NSUInteger)index {
	if (index >= self.machines.count) {
		return;
	}

	VLVMConfiguration *machine = self.machines[index];
	UIAlertController *alert =
		[UIAlertController alertControllerWithTitle:@"删除虚拟机"
											message:[NSString stringWithFormat:
													 @"「%@」以及它的所有磁盘镜像、ISO 文件都会被永久删除，无法恢复。",
													 machine.name]
									 preferredStyle:UIAlertControllerStyleAlert];

	__weak typeof(self) weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"删除"
											  style:UIAlertActionStyleDestructive
											handler:^(UIAlertAction *action) {
		[weakSelf deleteMachineAtIndex:index];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"取消"
											  style:UIAlertActionStyleCancel
											handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteMachineAtIndex:(NSUInteger)index {
	if (index >= self.machines.count) {
		return;
	}

	VLVMConfiguration *machine = self.machines[index];
	BOOL wasSelected = self.tableView.indexPathForSelectedRow != nil &&
		self.tableView.indexPathForSelectedRow.row == (NSInteger)index;

	if (![VLVMStore.sharedStore removeMachine:machine]) {
		UIAlertController *error =
			[UIAlertController alertControllerWithTitle:@"删除失败"
												message:@"磁盘文件删不掉，可能是外接存储已断开。虚拟机仍保留在列表里。"
										 preferredStyle:UIAlertControllerStyleAlert];
		[error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:error animated:YES completion:nil];
		return;
	}
	self.machines = [VLVMStore.sharedStore.machines mutableCopy];
	[VLStartupLog log:@"已删除虚拟机（含磁盘文件）：%@", machine.name];

	[self.tableView deleteRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)index inSection:0] ]
						  withRowAnimation:UITableViewRowAnimationAutomatic];

	if (self.machines.count == 0) {
		// 列表空了，右侧回到空状态。
		[self.selectionDelegate sidebarViewController:self didSelectConfiguration:nil];
		return;
	}
	if (!wasSelected) {
		return;
	}

	// 删掉的是当前选中项，自动选中相邻的一台。
	NSUInteger target = MIN(index, self.machines.count - 1);
	[self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)target inSection:0]
								animated:NO
						  scrollPosition:UITableViewScrollPositionNone];
	[self.selectionDelegate sidebarViewController:self didSelectConfiguration:self.machines[target]];
}

@end
