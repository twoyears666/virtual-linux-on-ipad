// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <UIKit/UIKit.h>

@class VLLinuxVirtualMachine;

/// 客户机键盘输入。两条路同时走：
/// 1. 外接硬件键盘：本视图做第一响应者，用 UIKit 的按键事件（UIKey）直接收键，
///    不弹系统软键盘，也不留那个不可见的输入框；
/// 2. 屏幕底部一排单键（Esc/Tab/方向/回车/退格），没有外接键盘时也能操作安装器。
@interface VLKeyInputView : UIView

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine;

/// 抢回第一响应者。切回本页、点完按钮之后都要调一次，否则硬件键盘事件收不到。
- (void)focus;

/// 唤起系统软键盘（控制条上的键盘按钮用）。没接外接键盘时才需要。
- (void)showSoftKeyboard;

/// 收起系统软键盘。
- (void)hideSoftKeyboard;

@end
