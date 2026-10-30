// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>
#import <stddef.h>
#import <stdint.h>

/// 退出原因，编号与 Hypervisor.framework 的 hv_exit_reason_t 一致。
typedef NS_ENUM(uint32_t, VLHypervisorExitReason) {
	VLHypervisorExitReasonCanceled = 0,
	VLHypervisorExitReasonException = 1,
	VLHypervisorExitReasonVTimer = 2,
	VLHypervisorExitReasonUnknown = 3,
};

/// vCPU 退出信息。布局对齐 hv_vcpu_exit_t（reason 4 字节 + 4 字节填充 + 16 字节联合体）。
typedef struct {
	uint32_t reason;
	uint32_t reserved;
	union {
		struct {
			uint64_t syndrome;
			/// FAR_EL1：出错时客户机用的虚拟地址。
			uint64_t virtualAddress;
			/// FAR_EL2：同一次访问在第二阶段（物理）看到的目标地址。只有数据异常有效；
			/// 内核开了 MMU 之后设备访问必须靠它定位，拿虚拟地址是找不到设备的。
			uint64_t physicalAddress;
		} exception;
		struct {
			uint32_t vtimerIRQ;
			uint32_t reserved;
		} vtimer;
	} info;
} VLHypervisorExit;

/// 通用寄存器编号，必须和 hv_reg_t 完全对齐：
/// X0–X28 = 0–28，FP = 29，LR = 30，PC = 31，FPCR = 32，FPSR = 33，CPSR = 34。
static const uint32_t VLHypervisorRegisterPC = 31;
static const uint32_t VLHypervisorRegisterFPCR = 32;
static const uint32_t VLHypervisorRegisterFPSR = 33;
static const uint32_t VLHypervisorRegisterCPSR = 34;

/// ARM64 内存属性位（hv_memory_flags_t）。
typedef NS_OPTIONS(uint32_t, VLHypervisorMemoryFlags) {
	VLHypervisorMemoryRead = 1,
	VLHypervisorMemoryWrite = 2,
	VLHypervisorMemoryExecute = 4,
};

/// Hypervisor.framework 的加载器与调用表。
/// iPadOS 不提供 Hypervisor SDK，所有符号都在运行时用 dlsym 解析；
/// 二进制由用户自行从 macOS 抽取、重签后放进 App 的 Frameworks/。
@interface VLHypervisor : NSObject

+ (instancetype)shared;

/// 所有必需符号是否都解析成功。
@property (nonatomic, readonly) BOOL available;

/// 不可用原因；可用时为 nil。
@property (nonatomic, readonly, copy) NSString *failureReason;

/// 实际加载的二进制路径。
@property (nonatomic, readonly, copy) NSString *loadedPath;

/// 框架是否自带 vGIC（`hv_gic_*` 一族）。macOS 15 起才有；有的话可以把 GIC 整个交回框架。
/// 只作为能力探测，当前运行路径仍然走自研的 GICv2 模拟。
@property (nonatomic, readonly) BOOL gicAvailable;

/// 返回值 0 表示 HV_SUCCESS。
- (int32_t)createVirtualMachine;
- (int32_t)destroyVirtualMachine;

/// 把一段宿主内存映射进客户机物理地址空间。
- (int32_t)mapHostPointer:(void *)pointer
			guestAddress:(uint64_t)guestAddress
					size:(size_t)size
				  flags:(VLHypervisorMemoryFlags)flags;
- (int32_t)unmapGuestAddress:(uint64_t)guestAddress size:(size_t)size;

/// 创建 vCPU 并拿到它的退出信息指针（由框架持有，不需要释放）。
- (int32_t)createVCPU:(uint64_t *)vcpu exitInfo:(VLHypervisorExit **)exitInfo;
- (int32_t)destroyVCPU:(uint64_t)vcpu;
- (int32_t)runVCPU:(uint64_t)vcpu;
- (int32_t)exitVCPUs:(const uint64_t *)vcpus count:(uint32_t)count;

- (int32_t)setRegister:(uint32_t)reg value:(uint64_t)value forVCPU:(uint64_t)vcpu;
- (int32_t)getRegister:(uint32_t)reg value:(uint64_t *)value forVCPU:(uint64_t)vcpu;

/// 设置待处理的 IRQ。GIC 处理完一次中断后要把 pending 清掉。
- (int32_t)setPendingIRQ:(BOOL)pending forVCPU:(uint64_t)vcpu;

@end
