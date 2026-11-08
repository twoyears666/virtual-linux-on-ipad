// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <UIKit/UIKit.h>

#import "VLTerminalEmulator.h"

/// 把 VLTerminalEmulator 的 80x25 字符网格画成黑底终端。
/// 等比缩放铺满自身，四周留黑边，绝不裁切；光标画成实心方块。
@interface VLTerminalView : UIView

@property (nonatomic, strong) VLTerminalEmulator *emulator;

@end
