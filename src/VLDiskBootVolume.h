// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>
#import <stdint.h>

/// 系统盘镜像里那块由安装器创建的 FAT 分区（放内核 / initrd / 内核命令行）。
/// 只读：解析 GPT 分区表，扫描各分区找 FAT16/FAT32，再按 8.3 短名取文件。
@interface VLDiskBootVolume : NSObject

+ (instancetype)volumeWithDiskImagePath:(NSString *)imagePath;

/// 打开镜像、定位分区、读出 VLBOOT.CFG。找不到启动分区就返回 NO（调用方会回退到 ISO 内核）。
- (BOOL)openWithError:(NSError **)error;

/// 安装时写下的内核命令行（VLBOOT.CFG 内容，去掉首尾空白与换行）。
@property (nonatomic, readonly, copy) NSString *commandLine;

/// 按 8.3 短名读文件，例如 @"VMLINUZ" / @"INITRD"（比较时不区分大小写）。找不到返回 nil。
- (NSData *)dataForFileNamed:(NSString *)name error:(NSError **)error;

/// 关掉底层句柄；可重复调用。
- (void)close;

@end
