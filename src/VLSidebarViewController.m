#import "VLSidebarViewController.h"

#import "VLCreateMachineViewController.h"
#import "VLDistroIcon.h"
#import "VLStartupLog.h"
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
	self.navigationItem.rightBarButtonItem = addItem;
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
	cell.textLabel.text = machine.name;
	cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	cell.detailTextLabel.text = machine.summary;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	// 自定义图标优先，没导入时才用发行版官方图标。
	UIImage *customIcon = machine.iconPath.length > 0
		? [UIImage imageWithContentsOfFile:machine.iconPath]
		: nil;
	cell.imageView.image = customIcon != nil
		? [VLDistroIcon thumbnailForImage:customIcon size:28.0]
		: [VLDistroIcon thumbnailForIdentifier:machine.distroIdentifier size:28.0];
	cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
	cell.accessoryType = UITableViewCellAccessoryNone;

	return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[self.selectionDelegate sidebarViewController:self
						   didSelectConfiguration:self.machines[(NSUInteger)indexPath.row]];
}

@end
