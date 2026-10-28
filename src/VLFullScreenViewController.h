#import <UIKit/UIKit.h>

#import "VLDisplayView.h"

@class VLLinuxVirtualMachine;

/// 全屏运行客户机：整屏黑底，画面恒定 4:3 居中。
/// 台前调度把窗口缩小、或屏幕本身不是 4:3 时，多余的地方留黑边，不做拉伸。
@interface VLFullScreenViewController : UIViewController

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine;

/// 点「键盘」时回调出去：系统键盘和按键翻译都在详情页那边，这里不重复实现。
@property (nonatomic, copy) void (^keyboardRequestHandler)(void);

/// 用户主动退出全屏时回调，详情页据此记住「别再自动弹回来」。
/// 注意：程序自己 dismiss（例如虚拟机停止）不会触发它。
@property (nonatomic, copy) void (^dismissHandler)(void);

- (void)updateStatus:(NSString *)status;
- (void)updateFrameWidth:(uint32_t)width height:(uint32_t)height data:(NSData *)data;
- (void)clearFrame;

@end
