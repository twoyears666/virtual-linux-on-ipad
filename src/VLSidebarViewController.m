#import "VLSidebarViewController.h"

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
	VLVMConfiguration *machine = [VLVMStore.sharedStore addMachine];
	self.machines = [VLVMStore.sharedStore.machines mutableCopy];
	[self.tableView reloadData];

	NSUInteger index = self.machines.count - 1;
	[self selectConfigurationAtIndex:index];
	[self.selectionDelegate sidebarViewController:self
						   didSelectConfiguration:self.machines[index]];
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
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", machine.summary, machine.bootModeString];
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.imageView.image = [UIImage systemImageNamed:@"desktopcomputer"];
	cell.imageView.tintColor = tableView.tintColor;
	cell.accessoryType = UITableViewCellAccessoryNone;

	return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[self.selectionDelegate sidebarViewController:self
						   didSelectConfiguration:self.machines[(NSUInteger)indexPath.row]];
}

@end
