#import <UIKit/UIKit.h>

#import "VLDisplayView.h"

@class VLLinuxVirtualMachine;

/// 客户机的独立全屏页面：整屏就是画面，状态和串口输出只作为叠加提示。
/// 和 Virtual Mac 一样，启动后离开设置页直接进这里。
@interface VLFullScreenViewController : UIViewController

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine;

/// 用户主动退出全屏时回调，详情页据此记住「别再自动弹回来」。
/// 注意：程序自己 dismiss（例如虚拟机停止）不会触发它。
@property (nonatomic, copy) void (^dismissHandler)(void);

- (void)updateStatus:(NSString *)status;
- (void)updateFrameWidth:(uint32_t)width height:(uint32_t)height data:(NSData *)data;
- (void)clearFrame;

/// 追加一行客户机串口输出。没有画面时，内核启动日志就是这页真正能看到的内容。
- (void)appendConsoleLine:(NSString *)line;

@end
