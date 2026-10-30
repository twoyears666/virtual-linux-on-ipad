// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>
#import <stddef.h>
#import <stdint.h>

/// 客户机物理内存：宿主侧用 mmap 拿一块按页对齐的内存，再映射到客户机地址空间。
/// 设备（virtio 队列、显存）都通过这里读写客户机内存。
@interface VLGuestMemory : NSObject

@property (nonatomic, readonly) uint64_t guestAddress;
@property (nonatomic, readonly) size_t size;
/// 宿主虚拟地址；映射失败或已释放时为 NULL。
@property (nonatomic, readonly) void *hostPointer;

- (instancetype)initWithSize:(size_t)size guestAddress:(uint64_t)guestAddress;

/// 分配并映射内存，失败返回 NO 并写 error。
- (BOOL)allocateWithError:(NSError **)error;

/// 解除映射并释放内存。
- (void)deallocate;

/// 客户机物理地址 → 宿主指针；越界返回 NULL。
- (void *)hostPointerForGuestAddress:(uint64_t)guestAddress length:(size_t)length;

/// 把一段数据写进客户机内存。
- (BOOL)writeData:(NSData *)data atGuestAddress:(uint64_t)guestAddress;

/// 把文件内容读进客户机内存，返回实际字节数；失败返回 -1。
- (NSInteger)loadFileAtPath:(NSString *)path atGuestAddress:(uint64_t)guestAddress;

@end
