// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <UIKit/UIKit.h>

#import "VLVMConfiguration.h"

@class VLDetailViewController;

@protocol VLDetailViewControllerDelegate <NSObject>

- (void)detailViewControllerDidChangeConfiguration:(VLDetailViewController *)controller;

@end

/// 右栏：虚拟机画面占位 + 全部设置项，直接在右侧修改，不需要再进弹窗。
@interface VLDetailViewController : UIViewController

@property (nonatomic, strong) VLVMConfiguration *configuration;
@property (nonatomic, weak) id<VLDetailViewControllerDelegate> changeDelegate;

@end
