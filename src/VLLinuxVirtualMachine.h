// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

@class VLTerminalEmulator;
@class VLVMConfiguration;

typedef NS_ENUM(NSInteger, VLVirtualMachineState) {
	VLVirtualMachineStateStopped = 0,
	VLVirtualMachineStateStarting,
	VLVirtualMachineStateRunning,
	VLVirtualMachineStateFailed,
};

@class VLLinuxVirtualMachine;

@protocol VLLinuxVirtualMachineDelegate <NSObject>

/// 状态变化（主线程回调）。
- (void)virtualMachine:(VLLinuxVirtualMachine *)machine
	   didChangeState:(VLVirtualMachineState)state
			   message:(NSString *)message;

/// 客户机刷新画面（主线程回调）。frame 为 BGRA 8888、行距紧密。
- (void)virtualMachine:(VLLinuxVirtualMachine *)machine
	 didUpdateFrameWidth:(uint32_t)width
				 height:(uint32_t)height
				   data:(NSData *)data;

/// 串口输出的一行（主线程回调）。
- (void)virtualMachine:(VLLinuxVirtualMachine *)machine didOutputLine:(NSString *)line;

@end

/// arm64 Linux 虚拟机：负责内存、设备、vCPU 主循环。
/// 只依赖运行时加载的 Hypervisor.framework，设备全部由本项目自己实现。
@interface VLLinuxVirtualMachine : NSObject

- (instancetype)initWithConfiguration:(VLVMConfiguration *)configuration;

@property (nonatomic, weak) id<VLLinuxVirtualMachineDelegate> delegate;

@property (nonatomic, readonly) VLVirtualMachineState state;
@property (nonatomic, readonly, copy) NSString *statusMessage;

/// 客户机串口控制台的字符网格。安装器把界面以 ANSI 转义序列画在 ttyAMA0 上，
/// 这里就是那些序列解析后的 80x25 结果，交给 VLTerminalView 显示。
@property (nonatomic, readonly) VLTerminalEmulator *terminal;

/// 启动。会先做能力校验，失败时立即返回 NO 并写 error。
- (BOOL)startWithError:(NSError **)error;

/// 请求停止（异步，状态回到 Stopped 时回调 delegate）。
- (void)stop;

/// 把 App 里的触摸位置（0 – 1，左上角原点）转成客户机触摸屏事件。
- (void)sendTouchBeganAtNormalizedX:(double)x y:(double)y;
- (void)sendTouchMovedToNormalizedX:(double)x y:(double)y;
- (void)sendTouchEnded;

/// 送一个 Linux evdev 按键码（KEY_A = 30 这一套），按下和抬起各调用一次。
- (void)sendKeycode:(uint16_t)keycode pressed:(BOOL)pressed;

/// 往串口（ttyAMA0）送一段文字。安装器的 stdin 是串口控制台，
/// 它不走 evdev，键盘必须从 PL011 的接收寄存器进去才能打字。
- (void)sendText:(NSString *)text;

@end
