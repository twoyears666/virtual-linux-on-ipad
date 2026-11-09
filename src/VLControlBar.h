// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VLControlBarCorner) {
	VLControlBarCornerTopLeft = 0,
	VLControlBarCornerTopRight,
	VLControlBarCornerBottomLeft,
	VLControlBarCornerBottomRight,
};

/// 悬浮在客户机画面上的控制条。只有「更多」时是一个圆；接了外接键盘、
/// 键盘按钮收起来时也还是一个圆。两个按钮都在时是左右圆、上下平的胶囊。
@interface VLControlBar : UIView

- (instancetype)initWithKeyboardHandler:(void (^)(void))keyboardHandler;

/// 挂在「更多」按钮上的菜单（回到主页、控制方式、退出）。
@property (nonatomic, copy) UIMenu *menu;

/// 贴在哪个角。改这个值会重建约束。
@property (nonatomic, assign) VLControlBarCorner corner;

/// 整体透明度，0.2–1.0。
@property (nonatomic, assign) CGFloat barOpacity;

/// 有没有键盘按钮（没接外接键盘时才有）。
@property (nonatomic, assign, getter=isKeyboardButtonVisible) BOOL keyboardButtonVisible;

@end
