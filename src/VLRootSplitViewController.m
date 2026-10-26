#import "VLRootSplitViewController.h"

#import "VLDetailViewController.h"
#import "VLSidebarViewController.h"
#import "VLStartupLog.h"
#import "VLVMStore.h"

@interface VLRootSplitViewController () <VLSidebarViewControllerDelegate,
										  VLDetailViewControllerDelegate>

@property (nonatomic, strong) VLSidebarViewController *sidebarViewController;
@property (nonatomic, strong) VLDetailViewController *detailViewController;

@end

@implementation VLRootSplitViewController

- (void)viewDidLoad {
	[super viewDidLoad];

	[VLStartupLog log:@"根控制器 viewDidLoad 进入"];

	self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
	self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
	[VLStartupLog log:@"分栏样式设置完成"];

	self.sidebarViewController = [[VLSidebarViewController alloc] init];
	self.sidebarViewController.selectionDelegate = self;

	self.detailViewController = [[VLDetailViewController alloc] init];
	self.detailViewController.changeDelegate = self;

	UINavigationController *primary =
		[[UINavigationController alloc] initWithRootViewController:self.sidebarViewController];
	primary.navigationBar.prefersLargeTitles = YES;

	UINavigationController *secondary =
		[[UINavigationController alloc] initWithRootViewController:self.detailViewController];
	secondary.navigationBar.prefersLargeTitles = YES;

	self.viewControllers = @[ primary, secondary ];
	[VLStartupLog log:@"左右两栏装载完成"];

	self.detailViewController.configuration = VLVMStore.sharedStore.machines.firstObject;
	[VLStartupLog log:@"详情控制器绑定配置完成"];

	[self.sidebarViewController selectConfigurationAtIndex:0];
	[VLStartupLog log:@"根控制器 viewDidLoad 完成"];
}

#pragma mark - VLSidebarViewControllerDelegate

- (void)sidebarViewController:(VLSidebarViewController *)controller
	 didSelectConfiguration:(VLVMConfiguration *)configuration {
	self.detailViewController.configuration = configuration;
	[self showDetailViewController:self.detailViewController.navigationController sender:nil];
}

#pragma mark - VLDetailViewControllerDelegate

- (void)detailViewControllerDidChangeConfiguration:(VLDetailViewController *)controller {
	[self.sidebarViewController reloadMachines];
}

@end
