// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVirtioMMIODevice.h"

/// virtio-blk（legacy）：把客户机的块读写落到一块磁盘镜像文件上。
/// 镜像本身是稀疏文件，读写用 pread/pwrite，不动客户机的物理内存。
@interface VLVirtioBlock : VLVirtioMMIODevice

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
						  imagePath:(NSString *)imagePath
						   readOnly:(BOOL)readOnly;

@property (nonatomic, copy, readonly) NSString *imagePath;
@property (nonatomic, assign, readonly) BOOL readOnly;
@property (nonatomic, assign, readonly) uint64_t capacityInBytes;

@end
