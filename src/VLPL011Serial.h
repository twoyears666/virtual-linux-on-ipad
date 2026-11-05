// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

#import "VLDevice.h"

@class VLInterruptController;

/// PL011 串口的最小实现：输出走数据寄存器，接收侧有一个小 FIFO，
/// 键盘打字时由 App 主动塞进去，安装器（d-i）从 /dev/ttyAMA0 读。
@interface VLPL011Serial : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController;

/// 把一段文字压进接收 FIFO，并按 IMSC 里的 RXIM 拉起中断。
- (void)injectText:(NSString *)text;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;

/// 每凑满一行回调一次（带上换行符）。
@property (nonatomic, copy) void (^textHandler)(NSString *line);

/// 客户机往数据寄存器写了多少个字符。用来判断内核到底有没有走到串口初始化，
/// 零就说明它死在更早的地方。
@property (nonatomic, readonly) NSUInteger writtenCharacterCount;

@end
