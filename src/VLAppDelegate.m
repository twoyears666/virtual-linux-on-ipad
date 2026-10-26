#import "VLAppDelegate.h"

#import "VLViewController.h"

@implementation VLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

	VLViewController *rootViewController = [[VLViewController alloc] initWithNibName:nil bundle:nil];
	UINavigationController *navigationController =
		[[UINavigationController alloc] initWithRootViewController:rootViewController];
	navigationController.navigationBar.prefersLargeTitles = YES;

	self.window.rootViewController = navigationController;
	[self.window makeKeyAndVisible];

	return YES;
}

@end
