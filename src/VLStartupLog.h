// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

// 启动/崩溃日志工具：把阶段埋点追加到 <虚拟机目录>/logs/startup.log，
// 把未捕获异常与致命信号写入 <虚拟机目录>/logs/crash.txt。
// 供盲修闪退时取回日志定位问题；UIFileSharingEnabled 已开启，可经文件 App 取回。
@interface VLStartupLog : NSObject

+ (void)installExceptionHandlers;
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// 把客户机 console 的原始字节流按原样追加到 startup.log：
/// 不加时间戳、不做换行处理，内核自己带的 [    0.123] 前缀才是原始时间线。
/// 按字节写也避开「一个 UTF-8 字符被拆到两次提交里」的乱码问题。
+ (void)appendGuestConsoleData:(NSData *)data;

@end