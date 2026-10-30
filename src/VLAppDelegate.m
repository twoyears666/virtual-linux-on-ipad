// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLAppDelegate.h"

#import "VLRootSplitViewController.h"
#import "VLStartupLog.h"
#import "VLStorageManager.h"

// 兜底界面：即使主界面初始化失败，也要能把失败原因显示出来（并写入日志）
static UIViewController *VLFallbackViewController(NSString *message) {
	UIViewController *controller = [[UIViewController alloc] init];

	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	label.textColor = UIColor.labelColor;
	label.text = message;

	controller.view.backgroundColor = UIColor.systemBackgroundColor;
	[controller.view addSubview:label];
	[NSLayoutConstraint activateConstraints:@[
		[label.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:24.0],
		[label.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-24.0],
		[label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
	]];

	return controller;
}

@implementation VLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	[VLStartupLog log:@"didFinishLaunching 进入"];

	// 恢复外接存储位置的安全作用域访问权，让已登记的目录重新可用。
	[VLStorageManager.sharedManager restoreAccess];
	[VLStartupLog log:@"存储位置已恢复：%lu 个",
		(unsigned long)VLStorageManager.sharedManager.locations.count];

	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	[VLStartupLog log:@"UIWindow 创建完成"];

	UIViewController *rootViewController = nil;
	@try {
		rootViewController = [[VLRootSplitViewController alloc] init];
		[VLStartupLog log:@"根控制器创建完成：%@", NSStringFromClass(rootViewController.class)];
	} @catch (NSException *exception) {
		[VLStartupLog log:@"根控制器创建抛异常：%@ %@", exception.name, exception.reason];
		rootViewController = VLFallbackViewController(
			[NSString stringWithFormat:@"界面初始化失败\n%@\n%@", exception.name, exception.reason]);
	}

	self.window.rootViewController = rootViewController;
	[self.window makeKeyAndVisible];
	[VLStartupLog log:@"窗口已显示"];

	// 主动跑一次布局，把 viewDidLoad 阶段的异常留在日志里，而不是静默闪退
	@try {
		[rootViewController.view layoutIfNeeded];
		[VLStartupLog log:@"首次布局完成，启动成功"];
	} @catch (NSException *exception) {
		[VLStartupLog log:@"首次布局抛异常：%@ %@", exception.name, exception.reason];
		self.window.rootViewController = VLFallbackViewController(
			[NSString stringWithFormat:@"界面布局失败\n%@\n%@", exception.name, exception.reason]);
	}

	return YES;
}

@end