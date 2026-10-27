#import <Foundation/Foundation.h>
#import <stdint.h>

#import "VLDevice.h"

@class VLGuestMemory;
@class VLInterruptController;

/// 一条 virtio 描述符：客户机内存地址、长度、是否可写（设备写入）。
@interface VLVirtioBufferDescriptor : NSObject

@property (nonatomic, assign, readonly) uint64_t address;
@property (nonatomic, assign, readonly) uint32_t length;
@property (nonatomic, assign, readonly) BOOL writable;

+ (instancetype)descriptorWithAddress:(uint64_t)address
							   length:(uint32_t)length
							 writable:(BOOL)writable;

@end

/// virtio-mmio（legacy v1）设备基类。
/// 寄存器、队列环、中断这些所有 virtio 设备都一样，放这里统一实现；
/// 子类只回答「我是几号设备」「有哪些特征」「配置空间长什么样」
/// 以及「来了一条描述符链该怎么处理」。
@interface VLVirtioMMIODevice : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;
@property (nonatomic, readonly) VLGuestMemory *guestMemory;

#pragma mark - 子类实现

/// virtio 设备号：网卡 1、磁盘 2、GPU 16、输入 18。
- (uint32_t)virtioDeviceID;
/// 设备特征位（低 32 位）。
- (uint32_t)virtioDeviceFeatures;
/// 队列深度上限，默认 8。
- (uint32_t)queueNumMax;
/// 处理一条描述符链，返回 used 环里要填的长度。
/// queueIndex 是这条链来自哪个队列（网卡 0 = 接收、1 = 发送）。
- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head
					   queueIndex:(uint32_t)queueIndex;
/// 是否在处理完链后立刻写 used 元素。输入设备要等真正有事件才回填，返回 NO。
- (BOOL)completesChainImmediately;
/// 配置空间（偏移 0x100 之后）的读，子类按自己的结构实现。
- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width;
- (void)writeConfigAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value;
/// 客户机把 Status 清零（复位）时调用。
- (void)resetDevice;

#pragma mark - 子类可用

/// 子类主动塞了数据（比如输入事件）后调用，把中断线拉起来。
- (void)raiseInterrupt;

/// 延迟完成的链：子类填完缓冲后调用，写 used 元素并拉中断。
- (void)completeChainWithHead:(uint16_t)head
					   length:(uint32_t)length
				   queueIndex:(uint32_t)queueIndex;

@end
