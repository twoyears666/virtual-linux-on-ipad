#import <UIKit/UIKit.h>

@class VLLinuxVirtualMachine;

/// 把系统键盘的输入翻译成客户机 evdev 按键事件。
/// 全屏页面会把详情页整个移出窗口，隐形输入框必须是「当前显示的那一页」的子视图
/// 才能成为第一响应者，所以做成独立对象：谁在显示，谁挂一个。
@interface VLKeyboardInput : NSObject

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine;

/// 目标虚拟机；换机器时改这里，没有机器时按键直接丢弃。
@property (nonatomic, strong) VLLinuxVirtualMachine *machine;

/// 把隐形输入框挂到页面视图上（重复调用是安全的）。
- (void)attachToView:(UIView *)view;

/// 弹出系统键盘；页面没挂过视图时什么都不做。
- (void)show;

/// 收起键盘。
- (void)hide;

@property (nonatomic, readonly, getter=isVisible) BOOL visible;

@end
