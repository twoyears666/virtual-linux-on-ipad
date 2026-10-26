#import "VLAppDelegate.h"

#import "VLRootSplitViewController.h"

@implementation VLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

	VLRootSplitViewController *rootViewController = [[VLRootSplitViewController alloc] init];
	self.window.rootViewController = rootViewController;
	[self.window makeKeyAndVisible];

	return YES;
}

@end
