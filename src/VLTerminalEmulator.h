// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

/// 终端的一个字符单元。character 为 0 表示空白。
typedef struct {
	uint32_t character;
	uint8_t foreground;
	uint8_t background;
	uint8_t attributes;
} VLTerminalCell;

/// ANSI 属性位
static const uint8_t VLTerminalAttributeBold = 1 << 0;
static const uint8_t VLTerminalAttributeReverse = 1 << 1;

@interface VLTerminalEmulator : NSObject

/// 固定 80x25：客户机串口控制台的默认尺寸就是这个，d-i 也按 80x25 排版。
- (instancetype)init;

@property (nonatomic, readonly) NSInteger columns;   // 恒为 80
@property (nonatomic, readonly) NSInteger rows;      // 恒为 25
@property (nonatomic, readonly) NSInteger cursorColumn;
@property (nonatomic, readonly) NSInteger cursorRow;
@property (nonatomic, readonly) BOOL cursorVisible;

/// 每次内容变化就 +1，UI 侧靠它判断要不要重画。
@property (nonatomic, readonly) uint64_t generation;

/// 喂原始字节（UTF-8 与控制序列都在里面）。
- (void)feed:(NSData *)data;

/// 清屏并复位解析状态：虚拟机重新启动时用，别让上一次的旧界面留在屏幕上。
- (void)reset;

/// 取一个单元，越界返回全 0。
- (VLTerminalCell)cellAtColumn:(NSInteger)column row:(NSInteger)row;

@end
