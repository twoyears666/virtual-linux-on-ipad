// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <UIKit/UIKit.h>

#import "VLVMConfiguration.h"

@class VLSidebarViewController;

@protocol VLSidebarViewControllerDelegate <NSObject>

- (void)sidebarViewController:(VLSidebarViewController *)controller
	 didSelectConfiguration:(VLVMConfiguration *)configuration;

@end

/// 左栏：虚拟机列表。
@interface VLSidebarViewController : UITableViewController

@property (nonatomic, weak) id<VLSidebarViewControllerDelegate> selectionDelegate;

- (void)selectConfigurationAtIndex:(NSUInteger)index;

/// 右侧改了配置后刷新列表里的名称与概要。
- (void)reloadMachines;

@end
