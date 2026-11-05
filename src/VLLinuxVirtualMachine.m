// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLLinuxVirtualMachine.h"

#import <math.h>
#import <mach/mach_time.h>
#import <string.h>
#import <sys/stat.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

#import "VLDeviceBus.h"
#import "VLDeviceTree.h"
#import "VLDiskBootVolume.h"
#import "VLDiskImage.h"
#import "VLGuestMemory.h"
#import "VLHostCapabilities.h"
#import "VLHypervisor.h"
#import "VLInterruptController.h"
#import "VLNetStack.h"
#import "VLPL011Serial.h"
#import "VLPVPanicDevice.h"
#import "VLStartupLog.h"
#import "VLVMConfiguration.h"
#import "VLVirtioBlock.h"
#import "VLVirtioConsole.h"
#import "VLVirtioGPU.h"
#import "VLVirtioInput.h"
#import "VLVirtioNet.h"

NSString *const VLLinuxVirtualMachineErrorDomain = @"com.twoyears666.virtuallinux.vm";

// 客户机物理地址规划（和 VLDeviceTree 里声明的一致）
static const uint64_t VLGuestMemoryBase = 0x80000000;
static const uint64_t VLPageSize = 0x1000;
static const uint64_t VLSegmentAlignment = 0x200000;
static const uint64_t VLUARTBase = 0x09000000;
static const uint64_t VLGICBase = 0x08000000;
static const uint64_t VLGPUBase = 0x0A000000;
static const uint64_t VLBlockBase = 0x0B000000;
static const uint64_t VLInputBase = 0x0C000000;
static const uint64_t VLNetBase = 0x0D000000;
static const uint64_t VLISOBase = 0x0E000000;

// GIC 中断号一律用 INTID：SGI 0–15、PPI 16–31、SPI 32 起。
// 设备树里 timer 节点的序号按 DT 约定写 13/14/11/10，内核解析时会加上 16，
// 所以客户机真正挂在 GIC 上的是 29/30/27/26；EL1 虚拟定时器是 INTID 27。
static const uint32_t VLGPUInterrupt = 34;
static const uint32_t VLBlockInterrupt = 35;
static const uint32_t VLInputInterrupt = 36;
static const uint32_t VLNetInterrupt = 37;
static const uint32_t VLISOInterrupt = 38;
/// virtio-console 在设备树里写的是 SPI 7，转成 INTID 就是 39。
static const uint32_t VLConsoleInterrupt = 39;
static const uint32_t VLPPIVirtualTimer = 27;
/// PL011 在设备树里是 SPI 1，转成 INTID 就是 33。
static const uint32_t VLUARTInterrupt = 33;

/// HVC 调用（PSCI）里的功能号
#define VL_PSCI_VERSION 0x84000000ULL
#define VL_PSCI_CPU_OFF 0x84000002ULL
#define VL_PSCI_CPU_ON 0x84000003ULL
#define VL_PSCI_AFFINITY_INFO 0x84000004ULL
#define VL_PSCI_SYSTEM_OFF 0x84000008ULL
#define VL_PSCI_SYSTEM_RESET 0x84000009ULL
#define VL_PSCI_RET_NOT_SUPPORTED ((uint64_t)-1)
#define VL_PSCI_RET_INVALID_PARAMETERS ((uint64_t)-2)
#define VL_PSCI_RET_ALREADY_ON ((uint64_t)-4)

/// 最多支持多少个 vCPU；设备树和 GIC 的 CPU 接口窗口都按这个上限预留。
#define VLMaximumCPUs 8

/// 一个 vCPU 的上下文。HVF 要求 hv_vcpu_create / hv_vcpu_run / hv_vcpu_destroy
/// 都在同一个线程上调用，所以句柄只能存在跑它的那个线程里，这里放的是跨线程可见的状态。
typedef struct {
	uint64_t vcpu;
	VLHypervisorExit *exitInfo;
	BOOL created;
	BOOL startRequested;
	BOOL finished;
	uint64_t startPC;
	uint64_t startContextID;
	/// 诊断用：这个核最后一次「有意义」的退出（WFI / 系统寄存器）停在哪儿。
	/// 卡住时一眼看出是哪个核停在哪个 PC，比猜便宜。
	uint64_t lastExitPC;
	uint32_t lastExitReason;
} VLVCPUSlot;


static uint64_t VLAlignUp(uint64_t value, uint64_t alignment) {
	return (value + alignment - 1) & ~(alignment - 1);
}

/// 读 arm64 Image 头部：偏移 0x08 是 text_offset，0x10 是 image_size（含 BSS，
/// 比文件长度大）。返回 NO 表示这不像一个 Image 头，调用方按旧约定处理。
static BOOL VLReadKernelImageHeader(NSData *kernel, NSString *path,
									uint64_t *textOffset, uint64_t *imageSize) {
	NSData *head = nil;
	if (kernel.length >= 0x40) {
		head = [kernel subdataWithRange:NSMakeRange(0, 0x40)];
	} else if (path.length > 0) {
		head = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
		if (head.length > 0x40) {
			head = [head subdataWithRange:NSMakeRange(0, 0x40)];
		}
	}
	if (head.length < 0x40) {
		return NO;
	}
	const uint8_t *bytes = head.bytes;
	uint64_t offset = 0;
	uint64_t size = 0;
	memcpy(&offset, bytes + 0x08, sizeof(offset));
	memcpy(&size, bytes + 0x10, sizeof(size));
	// 头部字段明显不合理就当没有头：宁可多加 2 MB 空隙，也不要把设备树写进内核保留区。
	if (size == 0 || size > (1ULL << 32)) {
		return NO;
	}
	*textOffset = offset;
	*imageSize = size;
	return YES;
}

/// 诊断标签：0 表示刚进客户机（还没退出），其余是异常的 EC 值。
static NSString *VLCPURestName(uint32_t reason) {
	switch (reason) {
		case 0x01: return @"WFI";
		case 0x18: return @"系统寄存器";
		default: return [NSString stringWithFormat:@"EC0x%x", reason];
	}
}

static uint32_t VLDeviceTreeBE32(const uint8_t *bytes, NSUInteger offset) {
	uint32_t value = 0;
	memcpy(&value, bytes + offset, sizeof(value));
	return __builtin_bswap32(value);
}

/// 诊断用：把刚生成好的 FDT 按层级打出来。设备树是手写的，串口一直
/// -EPROBE_DEFER 时，第一件要确认的事就是「这段字节里到底有没有 clock-uart
/// 节点、serial 的 clocks 指向几号 phandle」——不看一眼就只能猜内核为什么 defer。
static NSString *VLDescribeDeviceTree(NSData *blob) {
	if (blob.length < 56) {
		return @"设备树过短";
	}
	const uint8_t *bytes = blob.bytes;
	uint32_t structureOffset = VLDeviceTreeBE32(bytes, 8);
	uint32_t stringsOffset = VLDeviceTreeBE32(bytes, 12);
	if (structureOffset >= blob.length || stringsOffset >= blob.length) {
		return @"设备树偏移非法";
	}
	NSMutableString *text = [NSMutableString string];
	NSUInteger cursor = structureOffset;
	NSUInteger depth = 0;
	uint32_t token = 0;
	while (cursor + 4 <= blob.length) {
		token = VLDeviceTreeBE32(bytes, cursor);
		cursor += 4;
		if (token == 1) { // BEGIN_NODE
			const char *name = (const char *)(bytes + cursor);
			NSUInteger length = strlen(name);
			NSString *node = length > 0 ? [NSString stringWithUTF8String:name] : @"(根)";
			cursor += length + 1;
			cursor = (cursor + 3) & ~(NSUInteger)3;
			[text appendFormat:@"\n%@%@[", depth == 0 ? @"" : @"  ",
			 depth == 0 ? @"/" : node];
			depth++;
		} else if (token == 2) { // END_NODE
			[text appendString:@"]"];
			depth = depth > 0 ? depth - 1 : 0;
		} else if (token == 3) { // PROP
			if (cursor + 8 > blob.length) {
				break;
			}
			uint32_t length = VLDeviceTreeBE32(bytes, cursor);
			uint32_t nameOffset = VLDeviceTreeBE32(bytes, cursor + 4);
			cursor += 8;
			NSString *name = @"?";
			if (stringsOffset + nameOffset < blob.length) {
				name = [NSString stringWithUTF8String:(const char *)(bytes + stringsOffset + nameOffset)] ?: @"?";
			}
			if ([name isEqualToString:@"phandle"] || [name isEqualToString:@"clocks"]) {
				if (length >= 4 && cursor + 4 <= blob.length) {
					[text appendFormat:@"%@=%u ", name, VLDeviceTreeBE32(bytes, cursor)];
				} else {
					[text appendFormat:@"%@ ", name];
				}
			} else if (![name isEqualToString:@"compatible"] &&
					   ![name isEqualToString:@"reg"] &&
					   ![name isEqualToString:@"interrupts"] &&
					   ![name isEqualToString:@"clock-frequency"] &&
					   ![name isEqualToString:@"#clock-cells"] &&
					   ![name isEqualToString:@"#address-cells"] &&
					   ![name isEqualToString:@"#size-cells"]) {
				[text appendFormat:@"%@ ", name];
			}
			cursor += length;
			cursor = (cursor + 3) & ~(NSUInteger)3;
		} else if (token == 4) { // NOP
			continue;
		} else {
			break; // FDT_END 或损坏
		}
		if (text.length > 2400) {
			[text appendString:@"…"];
			break;
		}
	}
	return text;
}

@implementation VLLinuxVirtualMachine {
	VLVMConfiguration *_configuration;

	VLGuestMemory *_guestMemory;
	VLHypervisor *_hypervisor;
	VLDeviceBus *_deviceBus;
	VLInterruptController *_interruptController;
	VLPL011Serial *_serial;
	VLVirtioGPU *_gpu;
	VLVirtioBlock *_block;
	VLVirtioInput *_input;
	VLVirtioNet *_net;
	VLVirtioConsole *_console;
	VLPVPanicDevice *_pvPanic;
	VLNetStack *_network;
	VLVirtioBlock *_iso;

	NSUInteger _exitCount;
	BOOL _inputServicePending;
	/// 系统寄存器陷入的累计次数与已记录过的编码；只用来限制日志条数。
	NSUInteger _systemRegisterTrapCount;
	NSMutableSet<NSNumber *> *_trappedSystemRegisters;
	/// MMIO 访问的累计次数；第一次要留一行日志证明设备真的被访问到了。
	NSUInteger _mmioAccessCount;
	/// 没对上任何设备的访问次数，以及已经记过日志的地址（去重后限 16 条）。
	NSUInteger _unmappedAccessCount;
	NSMutableSet<NSNumber *> *_loggedUnmappedAddresses;

	/// 每个 vCPU 一份。0 号核跑在 runVirtualMachine 的线程上，其余各自一个线程。
	VLVCPUSlot _slots[VLMaximumCPUs];
	NSUInteger _cpuCount;
	NSCondition *_startCondition;
	NSRecursiveLock *_deviceLock;

	/// 每条中断线的「期望电平」（设备侧看到的），以及每个核已经真正下发给 HVF 的电平。
	/// HVF 的 pending 中断只能由负责跑这个 vCPU 的线程设置（不是跨线程安全的），
	/// 所以设备那边只记电平，由各核自己的循环在进客户机前把电平同步给 HVF。
	/// 电平而不是上升沿：拉低也必须下发，否则 HVF 的 IRQ 线会一直保持拉高。
	BOOL _irqLineLevel[VLMaximumCPUs];
	BOOL _irqLineApplied[VLMaximumCPUs];
	NSUInteger _irqInjectFailureCount;

	/// HVF 在 VTIMER_ACTIVATED 退出后会自动把该核的虚拟定时器屏蔽住，只有我们显式解除
	/// 才会再响。这里记「哪个核的定时器还处于被屏蔽状态」，等客户机 EOI 掉 INTID 27
	/// （此时它已经把下一次到期时间写回 CNTV_CVAL_EL0）再解除。
	BOOL _vtimerMasked[VLMaximumCPUs];
	NSUInteger _vtimerPendingCount;
	NSUInteger _vtimerLogCount;
	NSUInteger _vtimerUnmaskFailureCount;

	/// 每核累计的 VTIMER 退出次数与上次采样值。0.1.4 的日志只能靠「总退出速率
	/// ≈ 5×250 Hz」推断出 6 个核里只有 5 个在 tick；拆到每核就不必再推了。
	uint64_t _vtimerTally[VLMaximumCPUs];
	uint64_t _vtimerSampled[VLMaximumCPUs];
	/// 掩码自愈的次数（前 4 次记日志）。正常路径走 EOI 解除掩码，这里是兜底。
	NSUInteger _vtimerHealCount[VLMaximumCPUs];

	/// WFI 上「连着等了多久」的计数（一次 ≈ 1 ms），到 0.5 秒记一行，
	/// 卡死时直接看出核停在哪个 PC、是不是在等一个永远不来的中断。
	NSUInteger _wfiWaits[VLMaximumCPUs];
	NSUInteger _wfiStallLogCount;

	/// 每核 WFI/WFE 陷入的累计次数，以及最后一次的 PC / CPSR。
	/// 多核卡死时这两个值最直接：能看出哪个核停在哪个 PC、当时是否关中断在自旋。
	uint64_t _wfiTrapTally[VLMaximumCPUs];
	uint64_t _wfiTrapPC[VLMaximumCPUs];
	uint64_t _wfiTrapCPSR[VLMaximumCPUs];
	NSUInteger _wfiMaskedLogCount[VLMaximumCPUs];

	/// 每核累计退出次数与上次采样值：某个核一整轮 10 秒 0 次退出，
	/// 说明它要么卡在客户机里、要么卡在 VMM 代码上，和「在 WFI 里空转」完全不同。
	uint64_t _cpuExitTally[VLMaximumCPUs];
	uint64_t _cpuExitSampled[VLMaximumCPUs];

	BOOL _stopRequested;
	BOOL _framePending;
	uint64_t _guestMemorySize;
	uint32_t _displayWidth;
	uint32_t _displayHeight;

	/// 运行采样：每 30 秒记一行 CPU / 内存 / 退出次数，用来判断是不是这台虚拟机
	/// 把整机的 CPU 或内存吃满，连累系统服务（例如媒体服务）被饿死。
	dispatch_source_t _usageTimer;

	/// 退出原因的累计计数（采样行里拆开打印）。卡死时如果只有「取消」在涨，
	/// 说明是 hv_vcpu_run 被反复踢出，而不是客户机真的在陷 MMIO。
	uint64_t _canceledExitCount;
	uint64_t _vtimerExitCount;
	uint64_t _exceptionExitCount;
	uint64_t _wfiTrapCount;
	uint64_t _sysregTrapCount;
	uint64_t _mmioTrapCount;
	uint64_t _totalExits;
	uint64_t _sampledExits;
}

- (instancetype)initWithConfiguration:(VLVMConfiguration *)configuration {
	self = [super init];
	if (self) {
		_configuration = configuration;
		_state = VLVirtualMachineStateStopped;
		_statusMessage = @"未运行";
		_displayWidth = 1024;
		_displayHeight = 768;
		_startCondition = [[NSCondition alloc] init];
		_deviceLock = [[NSRecursiveLock alloc] init];
		// 系统内存告警直接关系到「全机没声音」这类连锁反应，留一行日志好对时间点。
		[NSNotificationCenter.defaultCenter addObserver:self
											   selector:@selector(hostDidReceiveMemoryWarning:)
												   name:UIApplicationDidReceiveMemoryWarningNotification
												 object:nil];
	}
	return self;
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)hostDidReceiveMemoryWarning:(NSNotification *)notification {
	[VLStartupLog log:@"系统内存告警：本进程占用 %lu MB，可用 %lu MB，客户机 %llu MB",
	 (unsigned long)[VLHostCapabilities residentMemoryMB],
	 (unsigned long)[VLHostCapabilities availableMemoryMB],
	 (unsigned long long)(_guestMemorySize / (1024ULL * 1024ULL))];
}

#pragma mark - 启动与停止

- (BOOL)startWithError:(NSError **)error {
	if (_state == VLVirtualMachineStateStarting || _state == VLVirtualMachineStateRunning) {
		return YES;
	}

	VLHypervisor *hypervisor = VLHypervisor.shared;
	if (!hypervisor.available) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
										 code:1
									 userInfo:@{ NSLocalizedDescriptionKey : hypervisor.failureReason ?: @"Hypervisor 不可用" }];
		}
		return NO;
	}

	NSString *kernelPath = _configuration.kernelPath;
	if (kernelPath.length == 0 ||
		![NSFileManager.defaultManager fileExistsAtPath:kernelPath]) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
										 code:2
									 userInfo:@{ NSLocalizedDescriptionKey :
										 @"没有可用的内核：ISO 里没找到 vmlinuz，或路径已失效" }];
		}
		return NO;
	}

	_hypervisor = hypervisor;
	_stopRequested = NO;
	_exitCount = 0;
	_inputServicePending = NO;
	_systemRegisterTrapCount = 0;
	_trappedSystemRegisters = [NSMutableSet set];
	_mmioAccessCount = 0;
	_unmappedAccessCount = 0;
	_loggedUnmappedAddresses = [NSMutableSet set];
	[_startCondition lock];
	for (NSUInteger index = 0; index < VLMaximumCPUs; index++) {
		memset(&_slots[index], 0, sizeof(VLVCPUSlot));
	}
	memset(_irqLineLevel, 0, sizeof(_irqLineLevel));
	memset(_irqLineApplied, 0, sizeof(_irqLineApplied));
	_irqInjectFailureCount = 0;
	memset(_vtimerMasked, 0, sizeof(_vtimerMasked));
	_vtimerPendingCount = 0;
	_vtimerLogCount = 0;
	_vtimerUnmaskFailureCount = 0;
	memset(_vtimerTally, 0, sizeof(_vtimerTally));
	memset(_vtimerSampled, 0, sizeof(_vtimerSampled));
	memset(_vtimerHealCount, 0, sizeof(_vtimerHealCount));
	memset(_wfiWaits, 0, sizeof(_wfiWaits));
	_wfiStallLogCount = 0;
	memset(_wfiTrapTally, 0, sizeof(_wfiTrapTally));
	memset(_wfiTrapPC, 0, sizeof(_wfiTrapPC));
	memset(_wfiTrapCPSR, 0, sizeof(_wfiTrapCPSR));
	memset(_wfiMaskedLogCount, 0, sizeof(_wfiMaskedLogCount));
	memset(_cpuExitTally, 0, sizeof(_cpuExitTally));
	memset(_cpuExitSampled, 0, sizeof(_cpuExitSampled));
	_canceledExitCount = 0;
	_vtimerExitCount = 0;
	_exceptionExitCount = 0;
	_wfiTrapCount = 0;
	_sysregTrapCount = 0;
	_mmioTrapCount = 0;
	[_startCondition unlock];
	[self parseDisplayResolution];
	[self reportState:VLVirtualMachineStateStarting message:@"创建虚拟硬件…"];

	NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(runVirtualMachine) object:nil];
	thread.name = @"VirtualLinux.vCPU0";
	thread.qualityOfService = NSQualityOfServiceUserInteractive;
	[thread start];
	[self startUsageSampling];
	return YES;
}

/// 每 10 秒量一次自身的 CPU / 内存占用。用 UTILITY 队列上的定时器，少干扰客户机。
/// 10 秒而不是 30 秒：真机日志常常是卡住后很快就抓走，30 秒的采样行往往根本不存在。
- (void)startUsageSampling {
	if (_usageTimer != NULL) {
		return;
	}
	_totalExits = 0;
	_sampledExits = 0;
	_usageTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
										 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	dispatch_source_set_timer(_usageTimer,
							  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
							  (uint64_t)(10 * NSEC_PER_SEC),
							  (uint64_t)(2 * NSEC_PER_SEC));
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(_usageTimer, ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		[strongSelf logUsageSample];
	});
	dispatch_resume(_usageTimer);
}

- (void)logUsageSample {
	// 注意先取 CPU 采样：它自带「距上次调用」的时间基准。
	double cpuPercent = [VLHostCapabilities cpuPercentSinceLastSample];
	uint64_t exits = __atomic_load_n(&_totalExits, __ATOMIC_RELAXED);
	uint64_t delta = exits - _sampledExits;
	_sampledExits = exits;
	[VLStartupLog log:@"退出构成：取消 %llu、定时器 %llu、异常 %llu（MMIO %llu、WFI %llu、系统寄存器 %llu）",
	 (unsigned long long)__atomic_load_n(&_canceledExitCount, __ATOMIC_RELAXED),
	 (unsigned long long)__atomic_load_n(&_vtimerExitCount, __ATOMIC_RELAXED),
	 (unsigned long long)__atomic_load_n(&_exceptionExitCount, __ATOMIC_RELAXED),
	 (unsigned long long)__atomic_load_n(&_mmioTrapCount, __ATOMIC_RELAXED),
	 (unsigned long long)__atomic_load_n(&_wfiTrapCount, __ATOMIC_RELAXED),
	 (unsigned long long)__atomic_load_n(&_sysregTrapCount, __ATOMIC_RELAXED)];
	[VLStartupLog log:@"运行采样：CPU %.0f%%（%lu 核），占用 %lu MB，可用 %lu MB，退出 %llu 次/10 秒；各核 %@",
	 (double)cpuPercent, (unsigned long)_cpuCount,
	 (unsigned long)[VLHostCapabilities residentMemoryMB],
	 (unsigned long)[VLHostCapabilities availableMemoryMB],
	 (unsigned long long)delta,
	 [self describeProcessorStates]];
}

/// 每个核最后一次「有意义」的退出（WFI / 系统寄存器）停在哪儿。
/// 多核卡死时，这一串比任何猜测都直接：能看出是哪个核停在哪条指令上。
- (NSString *)describeProcessorStates {
	NSMutableString *text = [NSMutableString string];
	for (NSUInteger index = 0; index < _cpuCount; index++) {
		uint32_t reason = _slots[index].lastExitReason;
		if (index > 0) {
			[text appendString:@"，"];
		}
		if (reason == 0) {
			[text appendFormat:@"%lu=运行中", (unsigned long)index];
		} else {
			[text appendFormat:@"%lu=%@@0x%llx", (unsigned long)index, VLCPURestName(reason),
			 (unsigned long long)_slots[index].lastExitPC];
		}
		// WFI/WFE 是「每次循环都被重置」的状态位，采样常常正好撞上 0，看不出东西；
		// 这里再补上当核累计的 WFI 次数、最后一条 WFI 的 PC 和当时的 DAIF.I。
		uint64_t tally = __atomic_load_n(&_wfiTrapTally[index], __ATOMIC_RELAXED);
		if (tally > 0) {
			[text appendFormat:@"[WFI×%llu@0x%llx I=%d]", (unsigned long long)tally,
			 (unsigned long long)_wfiTrapPC[index],
			 (int)((_wfiTrapCPSR[index] >> 7) & 1)];
		}
		// 这一轮 10 秒里这个核退出了多少次。0 次 = 它在客户机里长跑或在 VMM 里被卡住。
		uint64_t exits = __atomic_load_n(&_cpuExitTally[index], __ATOMIC_RELAXED);
		uint64_t exitDelta = exits - _cpuExitSampled[index];
		_cpuExitSampled[index] = exits;
		[text appendFormat:@"[退出+%llu]", (unsigned long long)exitDelta];
		// 这个核这一轮 10 秒里被打了几次虚拟定时器。250 Hz 下正常应该是 2500 左右；
		// 明显偏低或为 0 就说明它的 tick 停摆了，而不是「核在忙」。
		uint64_t timers = __atomic_load_n(&_vtimerTally[index], __ATOMIC_RELAXED);
		uint64_t timerDelta = timers - _vtimerSampled[index];
		_vtimerSampled[index] = timers;
		[text appendFormat:@"[定时+%llu 掩码=%@ 激活=%@]",
		 (unsigned long long)timerDelta,
		 _vtimerMasked[index] ? @"是" : @"否",
		 [_interruptController isInterruptActive:VLPPIVirtualTimer forCPU:(uint32_t)index] ? @"是" : @"否"];
		// 中断线：设备侧看到的电平 / 已经下发给 HVF 的电平。两者不一致说明下发这一步没走到；
		// 两者都是高却仍然等不到中断，问题就在 HVF 的投递上。
		[text appendFormat:@"[线=%@ 下发=%@ 挂起=%u]",
		 _irqLineLevel[index] ? @"高" : @"低",
		 _irqLineApplied[index] ? @"高" : @"低",
		 [_interruptController highestPendingInterruptForCPU:(uint32_t)index]];
	}
	return text;
}

/// 只做诊断，不加锁：arm64 上对齐的 64/32 位写是原子的，
/// 最坏情况是采样线程读到一半新旧混搭的值，不影响运行。
- (void)noteCPURest:(uint64_t)pc reason:(uint32_t)reason forCPU:(NSUInteger)index {
	if (index >= VLMaximumCPUs) {
		return;
	}
	_slots[index].lastExitPC = pc;
	_slots[index].lastExitReason = reason;
}

- (void)stop {
	_stopRequested = YES;
	[self exitAllProcessors];
	[self reportState:VLVirtualMachineStateStopped message:@"已停止"];
}

/// 让所有已创建的 vCPU 立刻从 hv_vcpu_run 里出来，并把等开机的线程放掉。
- (void)exitAllProcessors {
	uint64_t handles[VLMaximumCPUs];
	uint32_t count = 0;
	[_startCondition lock];
	for (NSUInteger index = 0; index < _cpuCount; index++) {
		// 只对已经放出去的核调 exit；还没开机的核靠上面的 broadcast 唤醒后自然退出。
		if (_slots[index].created && _slots[index].startRequested && _slots[index].vcpu != 0) {
			handles[count++] = _slots[index].vcpu;
		}
	}
	[_startCondition broadcast];
	[_startCondition unlock];

	if (count > 0) {
		[_hypervisor exitVCPUs:handles count:count];
	}
}

/// 任意一个核出了没法处理的问题：整台机停下来，否则 0 号核会一直等其它核。
- (void)haltAllProcessors {
	_stopRequested = YES;
	[self exitAllProcessors];
}

- (BOOL)isStopRequested {
	return _stopRequested;
}

#pragma mark - 中断线

/// 设备侧的中断线变化：记下这个核的「期望电平」，电平由 0 变 1 时把目标核从
/// hv_vcpu_run 里踢出来。hv_vcpu_set_pending_interrupt 必须在管着这个 vCPU 的线程上
/// 调用（跨线程调会被拒），而 pending 中断也只在「进客户机」那一刻生效——目标核
/// 很可能正躺在 run 里自旋等中断（stop_machine 就是这样），不踢出来就永远轮不到下发。
- (void)recordIRQLine:(BOOL)asserted forCPU:(NSUInteger)index {
	if (index >= VLMaximumCPUs) {
		return;
	}
	uint64_t vcpu = 0;
	[_startCondition lock];
	BOOL rising = asserted && !_irqLineLevel[index];
	_irqLineLevel[index] = asserted;
	if (index < _cpuCount) {
		vcpu = _slots[index].vcpu;
	}
	[_startCondition unlock];
	// 只有拉高需要踢；拉低不用打断客户机，等它下次自然退出时同步即可。
	if (rising && vcpu != 0) {
		[_hypervisor exitVCPUs:&vcpu count:1];
	}
}

/// 由各核自己的线程调用：把设备侧的最新电平同步给 HVF。
/// 每一轮都必须重新下发，不能只在电平变化时下发：核在 WFI 里等中断时，
/// HVF 处理完一次 WFI 退出后 pending 位可能被吃掉，之后我们再也不下发，
/// 这个核就永远等不到中断（0.1.2 日志里核 0 的 INTID 27 就是这样丢掉的）。
- (void)injectPendingIRQForCPU:(NSUInteger)index vcpu:(uint64_t)vcpu {
	[_startCondition lock];
	BOOL level = _irqLineLevel[index];
	_irqLineApplied[index] = level;
	[_startCondition unlock];
	int32_t result = [_hypervisor setPendingIRQ:level forVCPU:vcpu];
	if (result != 0 && _irqInjectFailureCount < 4) {
		_irqInjectFailureCount++;
		[VLStartupLog log:@"下发中断失败（0x%x）：核 %lu", (unsigned)result, (unsigned long)index];
	}
}

/// 客户机 EOI 掉虚拟定时器中断（INTID 27）时解除 HVF 的定时器掩码。
/// 必须在跑这个 vCPU 的线程上调用；EOIR 正是这条线程处理 MMIO 时写进来的，天然满足。
/// 客户机在 EOIR 之前已经把下一次到期时间写回 CNTV_CVAL_EL0，所以这一刻解除不会立刻重复触发。
- (void)interruptEndedForCPU:(uint32_t)cpuIndex irq:(uint32_t)irq {
	if (irq != VLPPIVirtualTimer || cpuIndex >= VLMaximumCPUs) {
		return;
	}
	uint64_t vcpu = 0;
	[_startCondition lock];
	BOOL wasMasked = _vtimerMasked[cpuIndex];
	_vtimerMasked[cpuIndex] = NO;
	if (cpuIndex < _cpuCount) {
		vcpu = _slots[cpuIndex].vcpu;
	}
	[_startCondition unlock];

	if (!wasMasked || vcpu == 0) {
		return;
	}
	int32_t result = [_hypervisor setVTimerMask:NO forVCPU:vcpu];
	if (result != 0 && _vtimerUnmaskFailureCount < 3) {
		_vtimerUnmaskFailureCount++;
		[VLStartupLog log:@"解除虚拟定时器掩码失败（0x%x）：核 %u", (unsigned)result, cpuIndex];
	}
}

/// 虚拟定时器掩码自愈。只在这个核「明明空闲、定时器却再也不响」时才调用。
/// 有两条独立的路径都会让 tick 永久停摆：EOI 没走到、HVF 的掩码一直挂着；
/// 或者客户机确认了 27 却没写 EOIR，GIC 的 active 位把后续投递全挡住了。
/// 两处都清掉再刷新中断线，让挂起的 27 重新变成可投递。
- (void)recoverStuckVirtualTimerForCPU:(NSUInteger)cpuIndex vcpu:(uint64_t)vcpu {
	if (cpuIndex >= VLMaximumCPUs) {
		return;
	}
	BOOL wasMasked = _vtimerMasked[cpuIndex];
	BOOL wasActive = [_interruptController isInterruptActive:VLPPIVirtualTimer
													  forCPU:(uint32_t)cpuIndex];
	// 无条件重新下发一次「解除掩码」：HVF 的掩码状态没有 getter，我们记的
	// _vtimerMasked 只是软件侧的猜测。EOI 那条路径如果 setVTimerMask 失败、
	// 或者掩码被别的退出路径重新置上，软件标志就会与实际状态失真——
	// 0.2.0 日志里 CPU1 每 10 秒只有 1 次定时器退出、而采样却显示「掩码=否」，
	// 就是这种情况（真机上它已经停摆，标志却看着正常）。
	// 代价：正常空闲的核每 200 ms 也可能被强制解除一次，最多多几次空 tick。
	_vtimerMasked[cpuIndex] = NO;
	BOOL shouldLog = wasMasked || wasActive;
	int32_t result = [_hypervisor setVTimerMask:NO forVCPU:vcpu];
	if (result != 0 && _vtimerUnmaskFailureCount < 3) {
		_vtimerUnmaskFailureCount++;
		[VLStartupLog log:@"解除虚拟定时器掩码失败（0x%x）：核 %lu", (unsigned)result,
		 (unsigned long)cpuIndex];
	}
	if (wasActive) {
		[_interruptController releaseInterruptIfStuck:VLPPIVirtualTimer forCPU:(uint32_t)cpuIndex];
	}
	if (shouldLog && _vtimerHealCount[cpuIndex] < 4) {
		_vtimerHealCount[cpuIndex]++;
		[VLStartupLog log:@"虚拟定时器掩码自愈：核 %lu 空闲 200 ms 没有定时器退出（掩码=%@ active=%@）",
		 (unsigned long)cpuIndex, wasMasked ? @"是" : @"否", wasActive ? @"是" : @"否"];
	}
}

- (void)parseDisplayResolution {
	NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
	NSArray<NSString *> *parts =
		[_configuration.resolutionString componentsSeparatedByCharactersInSet:nonDigits];
	NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
	for (NSString *part in parts) {
		if (part.length > 0) {
			[numbers addObject:@(part.integerValue)];
		}
	}
	if (numbers.count >= 2) {
		uint32_t width = numbers[0].unsignedIntValue;
		uint32_t height = numbers[1].unsignedIntValue;
		if (width >= 320 && height >= 240) {
			_displayWidth = width;
			_displayHeight = height;
		}
	}
}

#pragma mark - vCPU 线程

- (void)runVirtualMachine {
	@autoreleasepool {
		NSError *error = nil;
		if (![self setupEnvironmentWithError:&error]) {
			[VLStartupLog log:@"虚拟化启动失败：%@", error.localizedDescription];
			[self reportFailure:error.localizedDescription];
			[self teardown];
			return;
		}

		[self reportState:VLVirtualMachineStateRunning message:@"客户机运行中"];
		// 0 号核在 setup 里已经标成开机状态；其余核先等在这儿，客户机发 PSCI CPU_ON 才动。
		for (NSUInteger index = 1; index < _cpuCount; index++) {
			NSThread *thread = [[NSThread alloc] initWithTarget:self
													   selector:@selector(runProcessor:)
														 object:@(index)];
			thread.name = [NSString stringWithFormat:@"VirtualLinux.vCPU%lu", (unsigned long)index];
			thread.qualityOfService = NSQualityOfServiceUserInteractive;
			[thread start];
		}
		[self runProcessor:@0];
		[self waitForProcessors];
		[self teardown];
		if (_state != VLVirtualMachineStateFailed) {
			[self reportState:VLVirtualMachineStateStopped message:@"已停止"];
		}
	}
}

/// 一个 vCPU 的全部一生：建 vCPU → 等开机 → 跑退出循环 → 销毁。必须全在同一个线程里做，
/// 这是 Hypervisor.framework 的硬性要求。
- (void)runProcessor:(NSNumber *)indexBox {
	NSUInteger index = indexBox.unsignedIntegerValue;
	@autoreleasepool {
		VLSetProcessorIndexForCurrentThread((uint32_t)index);

		uint64_t vcpu = 0;
		VLHypervisorExit *exitInfo = NULL;
		int32_t result = [_hypervisor createVCPU:&vcpu exitInfo:&exitInfo];
		if (result != 0) {
			[VLStartupLog log:@"vCPU %lu 创建失败（0x%x）", (unsigned long)index, (unsigned)result];
			[self finishProcessor:index];
			return;
		}

		[_startCondition lock];
		_slots[index].vcpu = vcpu;
		_slots[index].exitInfo = exitInfo;
		_slots[index].created = YES;
		[_startCondition broadcast];
		while (!_slots[index].startRequested && !_stopRequested) {
			[_startCondition wait];
		}
		BOOL shouldStart = _slots[index].startRequested && !_stopRequested;
		uint64_t startPC = _slots[index].startPC;
		uint64_t startContextID = _slots[index].startContextID;
		[_startCondition unlock];

		if (shouldStart) {
			[self configureStartupRegistersForCPU:index
											 vcpu:vcpu
											   pc:startPC
										contextID:startContextID];
			[self runProcessorLoopForCPU:index vcpu:vcpu exitInfo:exitInfo];
		}

		[_hypervisor destroyVCPU:vcpu];
		[self finishProcessor:index];
	}
}

- (void)finishProcessor:(NSUInteger)index {
	[_startCondition lock];
	_slots[index].vcpu = 0;
	_slots[index].created = NO;
	_slots[index].finished = YES;
	[_startCondition broadcast];
	[_startCondition unlock];
}

- (void)waitForProcessors {
	[_startCondition lock];
	for (;;) {
		BOOL allFinished = YES;
		for (NSUInteger index = 0; index < _cpuCount; index++) {
			if (!_slots[index].finished) {
				allFinished = NO;
				break;
			}
		}
		if (allFinished) {
			break;
		}
		[_startCondition wait];
	}
	[_startCondition unlock];
}

/// arm64 Linux 入口：PC 指向入口，x0 = 参数（0 号核是设备树地址，其余核是 PSCI 给的 context id）。
- (void)configureStartupRegistersForCPU:(NSUInteger)index
								   vcpu:(uint64_t)vcpu
									 pc:(uint64_t)pc
							  contextID:(uint64_t)contextID {
	[_hypervisor setRegister:VLHypervisorRegisterPC value:pc forVCPU:vcpu];
	[_hypervisor setRegister:0 value:contextID forVCPU:vcpu];
	[_hypervisor setRegister:1 value:0 forVCPU:vcpu];
	[_hypervisor setRegister:2 value:0 forVCPU:vcpu];
	[_hypervisor setRegister:3 value:0 forVCPU:vcpu];
	// EL1h，屏蔽 D/A/I/F
	[_hypervisor setRegister:VLHypervisorRegisterCPSR value:0x3C5 forVCPU:vcpu];

	if (index == 0) {
		[VLStartupLog log:@"vCPU 0 就绪：PC=0x%llx 内存=%llu MB",
		 (unsigned long long)pc,
		 (unsigned long long)(_guestMemorySize / (1024ULL * 1024ULL))];
	} else {
		[VLStartupLog log:@"vCPU %lu 就绪：PC=0x%llx context=0x%llx",
		 (unsigned long)index, (unsigned long long)pc, (unsigned long long)contextID];
	}
}

/// 系统盘里如果已经有装好的系统（安装器在启动分区里写了 VLBOOT.CFG），就把它当启动来源。
- (VLDiskBootVolume *)openInstalledSystemBootVolume {
	VLDiskImage *systemDisk = _configuration.disks.firstObject;
	if (systemDisk.path.length == 0 ||
		![NSFileManager.defaultManager fileExistsAtPath:systemDisk.path]) {
		return nil;
	}

	VLDiskBootVolume *volume = [VLDiskBootVolume volumeWithDiskImagePath:systemDisk.path];
	if (![volume openWithError:NULL]) {
		return nil;
	}
	[VLStartupLog log:@"系统盘里找到已装好的系统，内核命令行：%@", volume.commandLine];
	return volume;
}

- (BOOL)setupEnvironmentWithError:(NSError **)error {
	// 客机内存不能按配置要多少给多少：前台把整机内存吃满，系统会把后台服务
	// （首当其冲是媒体服务）挤进 jetsam，表现就是全机没声音、强退 App 才恢复。
	NSUInteger requestedMemoryMB = MAX((NSUInteger)_configuration.memoryMB, (NSUInteger)128);
	NSUInteger maximumMemoryMB = [VLHostCapabilities maximumGuestMemoryMB];
	NSUInteger effectiveMemoryMB = MIN(requestedMemoryMB, maximumMemoryMB);
	if (effectiveMemoryMB < requestedMemoryMB) {
		[VLStartupLog log:@"配置 %lu MB 内存，实际按 %lu MB 启动（本机 %lu MB，要给系统留出余量）",
		 (unsigned long)requestedMemoryMB, (unsigned long)effectiveMemoryMB,
		 (unsigned long)[VLHostCapabilities physicalMemoryMB]];
	}
	_guestMemorySize = (uint64_t)effectiveMemoryMB * 1024ULL * 1024ULL;
	[VLStartupLog log:@"本机内存 %lu MB，本进程可用 %lu MB，启动前占用 %lu MB",
	 (unsigned long)[VLHostCapabilities physicalMemoryMB],
	 (unsigned long)[VLHostCapabilities availableMemoryMB],
	 (unsigned long)[VLHostCapabilities residentMemoryMB]];
	[VLStartupLog log:@"虚拟定时器掩码接口：%@",
	 _hypervisor.vtimerMaskAvailable ? @"可用" : @"不可用（每个核只会有一次定时器中断）"];

	// 界面里的「CPU 核心数」在这里真正生效：0 号核直接开机，其余核等 PSCI CPU_ON。
	NSUInteger requestedCores = MAX((NSUInteger)1, _configuration.cpuCores);
	_cpuCount = MIN(requestedCores, (NSUInteger)VLMaximumCPUs);
	if (_cpuCount != requestedCores) {
		[VLStartupLog log:@"配置 %lu 核，实际按 %lu 核启动（上限 %d 核）",
		 (unsigned long)requestedCores, (unsigned long)_cpuCount, VLMaximumCPUs];
	}

	int32_t result = [_hypervisor createVirtualMachine];
	if (result != 0) {
		if (error != NULL) {
			*error = [self errorWithMessage:[NSString stringWithFormat:@"hv_vm_create 失败（0x%x）", (unsigned)result]];
		}
		return NO;
	}

	_guestMemory = [[VLGuestMemory alloc] initWithSize:(size_t)_guestMemorySize
										  guestAddress:VLGuestMemoryBase];
	if (![_guestMemory allocateWithError:error]) {
		return NO;
	}
	// 映射完再量一次：如果「占用」一次性跳涨等于客户机内存，说明这块内存是被整块占住的，
	// 那就必须靠启动时的上限来给系统留余量，运行时已经退不回去了。
	[VLStartupLog log:@"客户机内存 %llu MB 已映射，本进程占用 %lu MB，可用 %lu MB",
	 (unsigned long long)(_guestMemorySize / (1024ULL * 1024ULL)),
	 (unsigned long)[VLHostCapabilities residentMemoryMB],
	 (unsigned long)[VLHostCapabilities availableMemoryMB]];

	// 启动来源：系统盘里已经有装好的系统就优先用它（内核 / initrd / 命令行由安装器写在
	// 系统盘的 FAT 分区里），否则退回 ISO 里抽出来的那套安装内核。
	VLDiskBootVolume *bootVolume = [self openInstalledSystemBootVolume];
	NSData *diskKernel = [bootVolume dataForFileNamed:@"VMLINUZ" error:NULL];
	NSData *diskInitrd = [bootVolume dataForFileNamed:@"INITRD" error:NULL];

	// 内核：arm64 Image 头里的 text_offset 现在是 0，要求装到 2 MiB 对齐的物理地址。
	// 之前按老约定再加 0x80000，客户机直接报 "[Firmware Bug]: Kernel image misaligned
	// at boot"，运行时虚拟地址也整体高了 0x80000，日志里的 PC 全都对不上 kallsyms。
	uint64_t kernelTextOffset = 0;
	uint64_t kernelImageSize = 0;
	BOOL hasKernelHeader = VLReadKernelImageHeader(diskKernel, _configuration.kernelPath,
												   &kernelTextOffset, &kernelImageSize);
	uint64_t kernelAddress = VLGuestMemoryBase + (hasKernelHeader ? kernelTextOffset : 0);
	NSInteger kernelSize = 0;
	if (diskKernel.length > 0) {
		kernelSize = [_guestMemory writeData:diskKernel atGuestAddress:kernelAddress]
			? (NSInteger)diskKernel.length
			: 0;
	} else {
		kernelSize = [_guestMemory loadFileAtPath:_configuration.kernelPath
								   atGuestAddress:kernelAddress];
	}
	if (kernelSize <= 0) {
		if (error != NULL) {
			*error = [self errorWithMessage:@"内核镜像读取失败"];
		}
		return NO;
	}
	// 还在用 ISO 抽出来的安装内核，说明系统盘里没装成；这一轮要跑安装器。
	BOOL bootsFromInstallerKernel = diskKernel.length == 0;
	[VLStartupLog log:@"启动来源：%@（内核 %ld 字节）",
		bootsFromInstallerKernel ? @"ISO 安装内核" : @"系统盘里已装好的系统", (long)kernelSize];
	// 内核可能有十几 MB，装进客户机内存后立刻放掉。
	diskKernel = nil;

	// 内核头部声明的 image_size 含 BSS，比文件本身大。设备树必须放在这块保留区之外，
	// 否则内核启动后会把还在用的设备树当成空闲内存收走。
	uint64_t kernelFootprint = MAX((uint64_t)kernelSize, kernelImageSize);
	uint64_t cursor = VLAlignUp(kernelAddress + kernelFootprint, VLSegmentAlignment);

	// 设备树
	uint64_t deviceTreeAddress = cursor;
	cursor = VLAlignUp(deviceTreeAddress + 0x200000, VLSegmentAlignment);

	// initrd（可选）
	uint64_t initrdAddress = cursor;
	uint64_t initrdEnd = initrdAddress;
	NSInteger initrdSize = 0;
	if (diskInitrd.length > 0) {
		initrdSize = [_guestMemory writeData:diskInitrd atGuestAddress:initrdAddress]
			? (NSInteger)diskInitrd.length
			: 0;
	} else if (_configuration.initrdPath.length > 0) {
		initrdSize = [_guestMemory loadFileAtPath:_configuration.initrdPath
								   atGuestAddress:initrdAddress];
	}
	diskInitrd = nil;
	if (initrdSize > 0) {
		initrdEnd = initrdAddress + (uint64_t)initrdSize;
		cursor = VLAlignUp(initrdEnd, VLPageSize);
	} else {
		initrdAddress = 0;
		initrdEnd = 0;
	}

	if (cursor > VLGuestMemoryBase + _guestMemorySize) {
		if (error != NULL) {
			*error = [self errorWithMessage:@"内核与 initrd 超出客户机内存，请加大内存"];
		}
		return NO;
	}

	// 从系统盘启动时用安装器写下的那份命令行（里面有真实的 root=）。
	// 用 ISO 安装内核启动时走安装器自己的交互流程：它现在能正常起来、也能读键盘，
	// 不再塞 preseed 自动应答——否则每次挂上安装盘都会被重新分区。
	NSMutableString *bootArguments = [NSMutableString stringWithString:
		bootVolume.commandLine.length > 0
			? bootVolume.commandLine
			: @"console=ttyAMA0,115200 earlycon=pl011,0x09000000 loglevel=7 panic=1"];

	// 两个控制台同时注册：ttyAMA0 由内核内建驱动注册，最先可用，保证
	// /dev/console 一定能打开；hvc0 依赖客户机里的 virtio_console 驱动，
	// 存在时作为主控制台（cmdline 里靠后的 console 优先）。只写 hvc0 的话，
	// 驱动缺失时 /init 之后整台机完全静默（0.2.0 日志就是这样）。
	// 不要替换掉安装器写下的 console=ttyAMA0，它是兜底。
	if ([bootArguments rangeOfString:@"console=hvc0"].location == NSNotFound) {
		[bootArguments appendString:@" console=hvc0"];
	}
	// 调试期保留完整日志：console 注册、initramfs、rootfs 探测都要看得到。
	// 启动链稳定后再改回 loglevel=4 + quiet。
	[bootArguments replaceOccurrencesOfString:@"loglevel=4"
								   withString:@"loglevel=7"
									  options:0
										range:NSMakeRange(0, bootArguments.length)];
	if ([bootArguments rangeOfString:@"loglevel="].location == NSNotFound) {
		[bootArguments appendString:@" loglevel=7"];
	}
	if ([bootArguments rangeOfString:@"quiet"].location != NSNotFound) {
		[bootArguments replaceOccurrencesOfString:@"quiet"
									   withString:@""
										  options:0
											range:NSMakeRange(0, bootArguments.length)];
	}
	bootVolume = nil;

	// 设备树只能声明这一轮真的会挂上的 virtio 设备：声明了却没有对应设备，
	// 内核一探测就会命中「未实现的 MMIO 地址」，整台机直接停。
	BOOL hasBlockDisk = [self hasUsableSystemDisk];
	BOOL hasISODisc = _configuration.isoPath.length > 0 &&
		[NSFileManager.defaultManager fileExistsAtPath:_configuration.isoPath];

	NSData *deviceTree = [VLDeviceTree deviceTreeWithMemoryBase:VLGuestMemoryBase
													memorySize:_guestMemorySize
												 bootArguments:bootArguments
													 initrdStart:initrdAddress
													   initrdEnd:initrdEnd
													   cpuCount:_cpuCount
														uartBase:VLUARTBase
														 gicBase:VLGICBase
														 gpuBase:VLGPUBase
													   blockBase:VLBlockBase
														isoBase:VLISOBase
													   inputBase:VLInputBase
														 netBase:VLNetBase
													hasBlockDisk:hasBlockDisk
													   hasISODisc:hasISODisc];
	if (![_guestMemory writeData:deviceTree atGuestAddress:deviceTreeAddress]) {
		if (error != NULL) {
			*error = [self errorWithMessage:@"设备树写入失败"];
		}
		return NO;
	}
	[VLStartupLog log:@"设备树已写入 0x%llx（%lu 字节），内核 0x%llx（%ld 字节）",
	 (unsigned long long)deviceTreeAddress, (unsigned long)deviceTree.length,
	 (unsigned long long)kernelAddress, (long)kernelSize];
	// 串口一直 defer 时，先确认这段字节里到底有没有 clock-uart、clocks 指向几号
	// phandle；不看一眼就只能猜内核为什么 probe 不到时钟。
	[VLStartupLog log:@"设备树结构：%@", VLDescribeDeviceTree(deviceTree)];

	[self setupDevicesWithSystemDisk:hasBlockDisk isoDisc:hasISODisc];

	// 0 号核：PC = 内核装载地址，x0 = 设备树地址。vCPU 句柄要等它自己的线程去建，
	// 这里只把「开机目标和参数」记下来。
	[_startCondition lock];
	_slots[0].startPC = kernelAddress;
	_slots[0].startContextID = deviceTreeAddress;
	_slots[0].startRequested = YES;
	[_startCondition broadcast];
	[_startCondition unlock];

	[VLStartupLog log:@"%lu 核启动：内核 0x%llx，设备树 0x%llx，内存 %llu MB",
	 (unsigned long)_cpuCount,
	 (unsigned long long)kernelAddress, (unsigned long long)deviceTreeAddress,
	 (unsigned long long)(_guestMemorySize / (1024ULL * 1024ULL))];
	return YES;
}

/// 第一块盘有镜像才算可用（设备树和实际设备必须同时决定，否则会声明出空地址）。
- (BOOL)hasUsableSystemDisk {
	VLDiskImage *systemDisk = _configuration.disks.firstObject;
	return systemDisk.path.length > 0 &&
		[NSFileManager.defaultManager fileExistsAtPath:systemDisk.path];
}

- (void)setupDevicesWithSystemDisk:(BOOL)hasBlockDisk isoDisc:(BOOL)hasISODisc {
	_deviceBus = [[VLDeviceBus alloc] init];

	_interruptController = [[VLInterruptController alloc] initWithBaseAddress:VLGICBase
																	cpuCount:_cpuCount];
	__weak typeof(self) weakSelf = self;
	_interruptController.irqLineHandler = ^(uint32_t cpuIndex, BOOL asserted) {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		[strongSelf recordIRQLine:asserted forCPU:cpuIndex];
	};
	_interruptController.interruptEndHandler = ^(uint32_t cpuIndex, uint32_t irq) {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		[strongSelf interruptEndedForCPU:cpuIndex irq:irq];
	};
	[_deviceBus addDevice:_interruptController];

	_serial = [[VLPL011Serial alloc] initWithBaseAddress:VLUARTBase
										  interruptNumber:VLUARTInterrupt
										interruptController:_interruptController];
	_serial.textHandler = ^(NSString *line) {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		[VLStartupLog log:@"客户机：%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]];
		[strongSelf reportLine:line];
	};
	[_deviceBus addDevice:_serial];

	_gpu = [[VLVirtioGPU alloc] initWithBaseAddress:VLGPUBase
									  guestMemory:_guestMemory
								  interruptNumber:VLGPUInterrupt
							  interruptController:_interruptController
									   displayWidth:_displayWidth
									  displayHeight:_displayHeight];
	_gpu.frameHandler = ^(uint32_t width, uint32_t height, NSData *frame) {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		[strongSelf deliverFrameWidth:width height:height data:frame];
	};
	// 界面还在画上一帧时不重复打包整幅画面（3 MB 一次），等下一帧一起送。
	_gpu.frameAcceptHandler = ^BOOL {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return NO;
		}
		return !__atomic_load_n(&strongSelf->_framePending, __ATOMIC_RELAXED);
	};
	[_deviceBus addDevice:_gpu];

	// 显示设置里的帧率上限直接透给 GPU，超出的 FLUSH 先攒着，不白拷一遍。
	switch (_configuration.frameRateLimit) {
		case VLFrameRateLimit60:
			_gpu.maximumFramesPerSecond = 60;
			break;
		case VLFrameRateLimitUnlimited:
			_gpu.maximumFramesPerSecond = 0;
			break;
		case VLFrameRateLimit30:
		default:
			_gpu.maximumFramesPerSecond = 30;
			break;
	}

	// 系统盘：第一块盘的镜像挂到 virtio-blk，没有镜像就不挂。
	VLDiskImage *systemDisk = _configuration.disks.firstObject;
	if (hasBlockDisk) {
		_block = [[VLVirtioBlock alloc] initWithBaseAddress:VLBlockBase
											   guestMemory:_guestMemory
										   interruptNumber:VLBlockInterrupt
									 interruptController:_interruptController
											 imagePath:systemDisk.path
											  readOnly:systemDisk.readOnly];
		[_deviceBus addDevice:_block];
	} else {
		[VLStartupLog log:@"没有可用的系统盘镜像，virtio-blk 跳过"];
	}

	// 安装镜像：ISO 只读挂成第二块 virtio-blk，安装器才能从里面取软件包。
	NSString *isoPath = _configuration.isoPath;
	if (hasISODisc) {
		_iso = [[VLVirtioBlock alloc] initWithBaseAddress:VLISOBase
											 guestMemory:_guestMemory
										 interruptNumber:VLISOInterrupt
								   interruptController:_interruptController
											 imagePath:isoPath
											  readOnly:YES];
		[_deviceBus addDevice:_iso];
		[VLStartupLog log:@"安装镜像已挂载：%@（只读）", isoPath.lastPathComponent];
	} else {
		[VLStartupLog log:@"没有可挂载的安装镜像，virtio-blk（ISO）跳过"];
	}

	// 触摸屏：详情页里的手指位置通过它送进客户机。
	_input = [[VLVirtioInput alloc] initWithBaseAddress:VLInputBase
										   guestMemory:_guestMemory
									   interruptNumber:VLInputInterrupt
								 interruptController:_interruptController];
	[_deviceBus addDevice:_input];

	// 网络：virtio-net 只负责搬帧，ARP/DHCP/DNS/TCP 代理都在 VLNetStack 里。
	_network = [[VLNetStack alloc] init];
	[_network start];
	_net = [[VLVirtioNet alloc] initWithBaseAddress:VLNetBase
									   guestMemory:_guestMemory
								   interruptNumber:VLNetInterrupt
							 interruptController:_interruptController
										   network:_network];
	[_deviceBus addDevice:_net];

	// 控制台：hvc0 绑在 virtio-console 上，一次提交取走整段输出，
	// 不再按字符陷进 PL011 的 MMIO。PL011 留着给 earlycon 用。
	_console = [[VLVirtioConsole alloc] initWithBaseAddress:VLDeviceTreeConsoleBase()
											   guestMemory:_guestMemory
										   interruptNumber:VLConsoleInterrupt
									 interruptController:_interruptController];
	[_deviceBus addDevice:_console];

	// pvpanic：客户机 panic 时主动告诉我们，而不是等 20 秒后的 rcu stall。
	_pvPanic = [[VLPVPanicDevice alloc] initWithBaseAddress:VLDeviceTreePVPanicBase()];
	_pvPanic.panicHandler = ^(NSString *reason) {
		[VLStartupLog log:@"客户机 panic：%@", reason];
	};
	[_deviceBus addDevice:_pvPanic];

	// 把这一轮真实的 MMIO 布局记下来：以后再出现「未实现的 MMIO 地址」，
	// 一眼就能对出是哪个区间少挂了设备。
	[VLStartupLog log:@"MMIO 布局：GIC 0x%llx(+0x%x)、UART 0x%llx、GPU 0x%llx、block 0x%llx(%@)、"
					   @"input 0x%llx、net 0x%llx、ISO 0x%llx(%@)，virtio 每段 0x1000",
	 (unsigned long long)VLGICBase, _interruptController.regionSize,
	 (unsigned long long)VLUARTBase, (unsigned long long)VLGPUBase,
	 (unsigned long long)VLBlockBase, hasBlockDisk ? @"已挂" : @"未挂",
	 (unsigned long long)VLInputBase, (unsigned long long)VLNetBase,
	 (unsigned long long)VLISOBase, hasISODisc ? @"已挂" : @"未挂"];
}

- (void)runProcessorLoopForCPU:(NSUInteger)cpuIndex
						  vcpu:(uint64_t)vcpu
					  exitInfo:(VLHypervisorExit *)exitInfo {
	while (![self isStopRequested]) {
		// 每次退出都可能产生临时对象（画面数据），按迭代回收，避免长期运行内存一直涨。
		@autoreleasepool {
			__atomic_add_fetch(&_totalExits, 1, __ATOMIC_RELAXED);
			__atomic_add_fetch(&_cpuExitTally[cpuIndex], 1, __ATOMIC_RELAXED);
			// 进客户机前先标成「运行中」，退出后只有 WFI / 系统寄存器会改写它。
			_slots[cpuIndex].lastExitReason = 0;
			// 设备侧只记了中断线电平，真正下发给 HVF 必须在本线程、进客户机之前做。
			[self injectPendingIRQForCPU:cpuIndex vcpu:vcpu];
			int32_t result = [_hypervisor runVCPU:vcpu];
			if (result != 0) {
				[self reportFailure:[NSString stringWithFormat:@"hv_vcpu_run 失败（0x%x）", (unsigned)result]];
				return;
			}
			if (exitInfo == NULL) {
				[self reportFailure:@"Hypervisor 没有返回退出信息"];
				return;
			}

			uint32_t reason = exitInfo->reason;
			// 第一次退出最能说明底层通不通，单独记一条，省得靠猜。
			if (cpuIndex == 0 && _exitCount == 0) {
				_exitCount = 1;
				uint64_t pc = 0;
				[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
				uint64_t syndrome = reason == VLHypervisorExitReasonException
					? exitInfo->info.exception.syndrome
					: 0;
				uint64_t faultAddress = reason == VLHypervisorExitReasonException
					? exitInfo->info.exception.virtualAddress
					: 0;
				uint64_t faultPhysical = reason == VLHypervisorExitReasonException
					? exitInfo->info.exception.physicalAddress
					: 0;
				uint64_t cpsr = 0;
				[_hypervisor getRegister:VLHypervisorRegisterCPSR value:&cpsr forVCPU:vcpu];
				[VLStartupLog log:@"vCPU 首次退出：原因=%u PC=0x%llx ESR=0x%llx FAR=0x%llx "
								   @"IPA=0x%llx CPSR=0x%llx",
				 reason, (unsigned long long)pc, (unsigned long long)syndrome,
				 (unsigned long long)faultAddress, (unsigned long long)faultPhysical,
				 (unsigned long long)cpsr];
			}
			if (reason == VLHypervisorExitReasonCanceled) {
				__atomic_add_fetch(&_canceledExitCount, 1, __ATOMIC_RELAXED);
				continue;
			}
			// 输入和网络只在 0 号核上服务，多核时不会重复搬运同一批帧。
			if (cpuIndex == 0) {
				if (_inputServicePending) {
					_inputServicePending = NO;
					[_input servicePendingEvents];
				}
				// 网络栈攒下的下行帧要及时交给客户机，否则 TCP 会一直等。
				[_net serviceReceive];
			}
			if (reason == VLHypervisorExitReasonVTimer) {
				// 客户机虚拟定时器到期：把 INTID 27（EL1 虚拟定时器 PPI）挂到本核的 GIC 上。
				// 注意 HVF 在这次退出之后已经把该核的定时器自动屏蔽了，必须等客户机
				// EOI 掉 27（那时它已写好下一次到期时间）再解除，见 interruptEndedForCPU:irq:。
				_vtimerMasked[cpuIndex] = YES;
				_vtimerPendingCount++;
				__atomic_add_fetch(&_vtimerExitCount, 1, __ATOMIC_RELAXED);
				__atomic_add_fetch(&_vtimerTally[cpuIndex], 1, __ATOMIC_RELAXED);
				if (_vtimerLogCount < 3) {
					_vtimerLogCount++;
					uint64_t pc = 0;
					[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
					[VLStartupLog log:@"虚拟定时器到期：核 %lu PC=0x%llx，挂 INTID %u（累计 %lu 次）",
					 (unsigned long)cpuIndex, (unsigned long long)pc, VLPPIVirtualTimer,
					 (unsigned long)_vtimerPendingCount];
				}
				[_interruptController setIRQPending:VLPPIVirtualTimer];
				continue;
			}
			if (reason == VLHypervisorExitReasonException) {
				__atomic_add_fetch(&_exceptionExitCount, 1, __ATOMIC_RELAXED);
				if (![self handleExceptionForCPU:cpuIndex vcpu:vcpu exitInfo:exitInfo]) {
					return;
				}
				continue;
			}

			[self reportFailure:[NSString stringWithFormat:@"未知退出原因 %u", reason]];
			return;
		}
	}
}

#pragma mark - 异常处理

- (BOOL)handleExceptionForCPU:(NSUInteger)cpuIndex
						 vcpu:(uint64_t)vcpu
					 exitInfo:(VLHypervisorExit *)exitInfo {
	uint64_t syndrome = exitInfo->info.exception.syndrome;
	uint64_t address = exitInfo->info.exception.virtualAddress;
	uint32_t exceptionClass = (uint32_t)((syndrome >> 26) & 0x3F);

	if (exceptionClass == 0x24 || exceptionClass == 0x25) {
		__atomic_add_fetch(&_mmioTrapCount, 1, __ATOMIC_RELAXED);
		return [self handleDataAbortSyndrome:syndrome
							 virtualAddress:exitInfo->info.exception.virtualAddress
							physicalAddress:exitInfo->info.exception.physicalAddress
										cpu:cpuIndex
									   vcpu:vcpu];
	}
	if (exceptionClass == 0x01) {
		__atomic_add_fetch(&_wfiTrapCount, 1, __ATOMIC_RELAXED);
		// WFI/WFE 陷入：客户机在等中断。只有本核真的有能投递的挂起中断时，这条指令
		// 才算执行完（PC+4）；否则原地睡一会儿再重试同一条指令。
		// 之前无条件 PC+4 等于把 WFI 当 nop，客户机永远不会真睡，定时器中断也就
		// 永远「等不到」，多核会在第一个 wait_for_completion 上卡死。
		if (cpuIndex == 0 && _inputServicePending) {
			_inputServicePending = NO;
			[_input servicePendingEvents];
		}
		uint64_t pc = 0;
		[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
		[self noteCPURest:pc reason:exceptionClass forCPU:cpuIndex];
		uint64_t cpsr = 0;
		[_hypervisor getRegister:VLHypervisorRegisterCPSR value:&cpsr forVCPU:vcpu];
		BOOL irqMasked = (cpsr & (1ULL << 7)) != 0;
		// 记下这台核最后一次 WFI/WFE 的位置。采样行会带上这两个值，卡死时不用猜。
		__atomic_add_fetch(&_wfiTrapTally[cpuIndex], 1, __ATOMIC_RELAXED);
		_wfiTrapPC[cpuIndex] = pc;
		_wfiTrapCPSR[cpuIndex] = cpsr;
		if (irqMasked && _wfiMaskedLogCount[cpuIndex] < 2) {
			_wfiMaskedLogCount[cpuIndex]++;
			uint32_t highest = [_interruptController highestPendingInterruptForCPU:(uint32_t)cpuIndex];
			[VLStartupLog log:@"核 %lu 关中断执行 WFI/WFE：PC=0x%llx，挂起中断 %u",
			 (unsigned long)cpuIndex, (unsigned long long)pc, highest];
		}
		BOOL pending = [_interruptController hasPendingInterruptForCPU:(uint32_t)cpuIndex];
		if (!pending) {
			// 没有可投递的中断就谁也叫不醒这台核——真机上 WFI 会一直睡到 IRQ/FIQ 线
			// 拉起来，和 PSTATE.I 无关。0.1.4 把「关中断的 WFI」当成 nop 直接 PC+4，
			// 客户机的 idle 循环就变成每 2 微秒一次 WFI 的忙等，6 个核把宿主吃到 473%，
			// 还跟定时器线程抢 CPU。
			_wfiWaits[cpuIndex]++;
			if (_wfiWaits[cpuIndex] == 500 && _wfiStallLogCount < 8) {
				_wfiStallLogCount++;
				[VLStartupLog log:@"核 %lu 在 WFI 上已等 0.5 秒：PC=0x%llx，没有可投递的中断",
				 (unsigned long)cpuIndex, (unsigned long long)pc];
			}
			// 掩码自愈：HVF 的虚拟定时器掩码只该覆盖「客户机还没 EOI 掉 27」这一小段。
			// 这个核已经空闲 200 ms 却一次定时器退出都没来，就是掩码（或 active 位）
			// 卡住了；不救回来这个核的 tick 永久停摆（0.1.4 里 CPU1 就是这样：
			// rcu 报 timer-softirq=0、watchdog 报 hard LOCKUP）。
			if (_wfiWaits[cpuIndex] >= 200) {
				[self recoverStuckVirtualTimerForCPU:cpuIndex vcpu:vcpu];
				_wfiWaits[cpuIndex] = 0;
			}
			usleep(1000);
			return YES;
		}
		_wfiWaits[cpuIndex] = 0;
		[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:vcpu];
		return YES;
	}
	if (exceptionClass == 0x16) {
		return [self handleHypervisorCallForCPU:cpuIndex vcpu:vcpu];
	}
	if (exceptionClass == 0x18) {
		__atomic_add_fetch(&_sysregTrapCount, 1, __ATOMIC_RELAXED);
		// 系统寄存器陷入：Apple 的 Hypervisor 没实现这个寄存器（例如 ID_AA64ISAR2_EL1），
		// 内核一读就直接退出。按「该特性不存在」返回 0，然后跳过这条指令继续跑。
		uint64_t pc = 0;
		[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
		[self noteCPURest:pc reason:exceptionClass forCPU:cpuIndex];
		return [self handleSystemRegisterTrap:syndrome vcpu:vcpu];
	}

	uint64_t pc = 0;
	[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
	[self logProcessorSnapshotForCPU:cpuIndex vcpu:vcpu pc:pc];
	[self reportFailure:[NSString stringWithFormat:@"未处理的异常 EC=0x%x ESR=0x%llx FAR=0x%llx PC=0x%llx",
						 exceptionClass, (unsigned long long)syndrome,
						 (unsigned long long)address, (unsigned long long)pc]];
	return NO;
}

/// (Op0, Op1, CRn, CRm, Op2) 打包成一个键，顺手当「已记录过」的去重依据。
static uint32_t VLSystemRegisterKey(uint32_t op0, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2) {
	return (op0 << 14) | (op1 << 10) | (crn << 6) | (crm << 3) | op2;
}

/// 常见系统寄存器的名字；只为日志可读，认不出来就打印编码。
static NSString *VLSystemRegisterName(uint32_t key) {
	switch (key) {
		case 0xC000: return @"MIDR_EL1";
		case 0xC004: return @"ID_AA64PFR0_EL1";
		case 0xC005: return @"MPIDR_EL1";
		case 0xC006: return @"REVIDR_EL1";
		case 0xC024: return @"ID_AA64ZFR0_EL1";
		case 0xC025: return @"ID_AA64PFR1_EL1";
		case 0xC028: return @"ID_AA64DFR0_EL1";
		case 0xC029: return @"ID_AA64DFR1_EL1";
		case 0xC030: return @"ID_AA64ISAR0_EL1";
		case 0xC031: return @"ID_AA64ISAR1_EL1";
		case 0xC032: return @"ID_AA64ISAR2_EL1";
		case 0xC038: return @"ID_AA64MMFR0_EL1";
		case 0xC039: return @"ID_AA64MMFR1_EL1";
		case 0xC03A: return @"ID_AA64MMFR2_EL1";
		case 0xC03B: return @"ID_AA64MMFR3_EL1";
		case 0xCC01: return @"CTR_EL0";
		case 0xCC07: return @"DCZID_EL0";
		case 0xCF80: return @"CNTFRQ_EL0";
		case 0xCF81: return @"CNTPCT_EL0";
		case 0xCF82: return @"CNTVCT_EL0";
		default: return nil;
	}
}

/// 客户机看到的 24 MHz 计数器读数（和设备树里串口时钟口径一致）。
static uint64_t VLGuestCounterValue(void) {
	static mach_timebase_info_data_t timebase;
	if (timebase.denom == 0) {
		mach_timebase_info(&timebase);
	}
	uint64_t nanoseconds = mach_absolute_time() * timebase.numer / timebase.denom;
	return nanoseconds * 24 / 1000;
}

- (BOOL)handleSystemRegisterTrap:(uint64_t)syndrome vcpu:(uint64_t)vcpu {
	// ISS 布局（EC=0x18）：bit0 方向（1=读 MRS，0=写 MSR），[4:1] CRm，[9:5] Rt，
	// [13:10] CRn，[16:14] Op1，[19:17] Op2，[21:20] Op0。
	// 注意 Op1 是 3 位、CRn 从 bit10 起：之前按 [16:13]/[12:9] 取，名字就会整体错一位
	// （ID_AA64ISAR2_EL1 被认成「未知寄存器」就是这么来的）。
	uint32_t iss = (uint32_t)(syndrome & 0x1FFFFFF);
	BOOL isRead = (iss & 0x1) != 0;
	uint32_t crm = (iss >> 1) & 0xF;
	uint32_t rt = (iss >> 5) & 0x1F;
	uint32_t crn = (iss >> 10) & 0xF;
	uint32_t op1 = (iss >> 14) & 0x7;
	uint32_t op2 = (iss >> 17) & 0x7;
	uint32_t op0 = (iss >> 20) & 0x3;
	uint32_t key = VLSystemRegisterKey(op0, op1, crn, crm, op2);

	// ID 类寄存器返回 0 等于「这项特性不存在」，Linux 会走通用实现；但计数器频率、
	// 计数器读数和 MPIDR 会被内核直接拿去算，零值会把启动带进死胡同。
	uint64_t value = 0;
	switch (key) {
		case 0xCF80: // CNTFRQ_EL0
			value = 24000000;
			break;
		case 0xCF81: // CNTPCT_EL0
		case 0xCF82: // CNTVCT_EL0
			value = VLGuestCounterValue();
			break;
		case 0xC005: // MPIDR_EL1
			value = 0x80000000u | VLProcessorIndexForCurrentThread();
			break;
		case 0xC000: // MIDR_EL1：Cortex-A57，和设备树里的 compatible 对得上
			value = 0x411FD070u;
			break;
		default:
			value = 0;
			break;
	}
	if (isRead && rt < 31) {
		[_hypervisor setRegister:rt value:value forVCPU:vcpu];
	}

	// 同一个寄存器只记一次：以前每撞一次就刷一行，日志里全是重复的「错的都差不多」。
	_systemRegisterTrapCount++;
	NSNumber *keyBox = @(key);
	if (_trappedSystemRegisters.count < 32 &&
		![_trappedSystemRegisters containsObject:keyBox]) {
		[_trappedSystemRegisters addObject:keyBox];
		NSString *name = VLSystemRegisterName(key);
		NSString *label = name != nil
			? [NSString stringWithFormat:@"%@（op0=%u op1=%u CRn=%u CRm=%u op2=%u）",
										 name, op0, op1, crn, crm, op2]
			: [NSString stringWithFormat:@"未知寄存器（op0=%u op1=%u CRn=%u CRm=%u op2=%u）",
										 op0, op1, crn, crm, op2];
		[VLStartupLog log:@"系统寄存器陷入（%@）：%@，按 0x%llx 返回",
		 isRead ? @"读" : @"写", label, (unsigned long long)value];
	}

	uint64_t pc = 0;
	[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
	[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:vcpu];
	return YES;
}

- (BOOL)handleDataAbortSyndrome:(uint64_t)syndrome
				 virtualAddress:(uint64_t)virtualAddress
				physicalAddress:(uint64_t)physicalAddress
							cpu:(NSUInteger)cpuIndex
						   vcpu:(uint64_t)vcpu {
	uint64_t pc = 0;
	[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
	// 设备要按物理地址找：内核开了 MMU 之后访问设备用的是 ioremap 出来的虚拟地址，
	// 拿它当设备地址永远对不上（这就是以前「未实现的 MMIO」的真正原因）。
	uint64_t address = [self deviceAddressForVirtualAddress:virtualAddress
											 physicalAddress:physicalAddress];

	BOOL instructionValid = ((syndrome >> 24) & 0x1) != 0;
	if (!instructionValid) {
		// 解码不出是哪条指令也不能把整台机停掉：记一次、跳过它，其余核还能继续跑。
		[self noteUnmappedAccess:address
							width:0
						  isWrite:NO
							   pc:pc
							  cpu:cpuIndex
							 vcpu:vcpu
				   virtualAddress:virtualAddress
				  physicalAddress:physicalAddress];
		[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:vcpu];
		return YES;
	}

	uint32_t widthCode = (uint32_t)((syndrome >> 22) & 0x3);
	uint32_t width = 1u << widthCode;
	BOOL isWrite = ((syndrome >> 6) & 0x1) != 0;
	uint32_t registerIndex = (uint32_t)((syndrome >> 16) & 0x1F);

	// 多个核可能同时触发 MMIO 异常，设备状态不是线程安全的，串行进出。
	[_deviceLock lock];
	BOOL handled = NO;
	if (isWrite) {
		uint64_t value = 0;
		[_hypervisor getRegister:registerIndex value:&value forVCPU:vcpu];
		handled = [self writeValue:value width:width address:address];
	} else {
		uint64_t value = 0;
		handled = [self readValue:&value width:width address:address];
		if (handled) {
			[_hypervisor setRegister:registerIndex value:value forVCPU:vcpu];
		}
	}
	[_deviceLock unlock];

	if (_mmioAccessCount == 0) {
		// 只记第一次：既证明设备真的被访问到了，也不会把日志刷满。
		[VLStartupLog log:@"首个 MMIO 访问：设备地址 0x%llx（虚拟地址 0x%llx，物理地址 0x%llx）"
						   @"%u 字节%@，%@",
		 (unsigned long long)address, (unsigned long long)virtualAddress,
		 (unsigned long long)physicalAddress, width, isWrite ? @"写" : @"读",
		 handled ? @"已命中设备" : @"没有对应设备"];
	}
	_mmioAccessCount++;

	if (!handled) {
		// 没对上设备不再当成致命错误：小毛病就停下整台机，代价太大。
		// 记一次（去重、限 16 条）+ 打一份处理器快照，然后当读 0 / 写丢弃继续跑。
		[self noteUnmappedAccess:address
							width:width
						  isWrite:isWrite
							   pc:pc
							  cpu:cpuIndex
							 vcpu:vcpu
				   virtualAddress:virtualAddress
				  physicalAddress:physicalAddress];
		if (!isWrite) {
			[_hypervisor setRegister:registerIndex value:0 forVCPU:vcpu];
		}
	}

	// 虚拟机停在触发异常的那条指令上，模拟完要自己往前推一条，否则会反复触发。
	[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:vcpu];
	return YES;
}

/// 设备地址的选择：物理地址落在已知区间（内存或某个设备）就信它；否则退回虚拟地址
/// （内核早期 MMU 还没开时，两者本来就是同一个值）。
- (uint64_t)deviceAddressForVirtualAddress:(uint64_t)virtualAddress
						   physicalAddress:(uint64_t)physicalAddress {
	if ([self isKnownGuestAddress:physicalAddress]) {
		return physicalAddress;
	}
	if ([self isKnownGuestAddress:virtualAddress]) {
		return virtualAddress;
	}
	return physicalAddress != 0 ? physicalAddress : virtualAddress;
}

- (BOOL)isKnownGuestAddress:(uint64_t)address {
	if (address >= VLGuestMemoryBase && address - VLGuestMemoryBase < _guestMemorySize) {
		return YES;
	}
	return [_deviceBus containsAddress:address];
}

/// 记录一次「没对上设备」的访问，并在第一次遇到某个地址时打一份快照。
- (void)noteUnmappedAccess:(uint64_t)address
					 width:(uint32_t)width
				   isWrite:(BOOL)isWrite
						pc:(uint64_t)pc
					   cpu:(NSUInteger)cpuIndex
					  vcpu:(uint64_t)vcpu
			virtualAddress:(uint64_t)virtualAddress
		   physicalAddress:(uint64_t)physicalAddress {
	_unmappedAccessCount++;
	NSNumber *addressBox = @(address);
	if ([_loggedUnmappedAddresses containsObject:addressBox] ||
		_loggedUnmappedAddresses.count >= 16) {
		return;
	}
	[_loggedUnmappedAddresses addObject:addressBox];
	if (width == 0) {
		[VLStartupLog log:@"客户机访问了没有设备的地址 0x%llx（指令无法解码，虚拟地址 0x%llx，"
						   @"物理地址 0x%llx），核 %lu，PC=0x%llx，已跳过（累计 %lu 次）",
		 (unsigned long long)address, (unsigned long long)virtualAddress,
		 (unsigned long long)physicalAddress, (unsigned long)cpuIndex,
		 (unsigned long long)pc, (unsigned long)_unmappedAccessCount];
	} else {
		[VLStartupLog log:@"客户机访问了没有设备的地址 0x%llx（%u 字节%@，虚拟地址 0x%llx，"
						   @"物理地址 0x%llx），核 %lu，PC=0x%llx，已按忽略处理（累计 %lu 次）",
		 (unsigned long long)address, width, isWrite ? @"写" : @"读",
		 (unsigned long long)virtualAddress, (unsigned long long)physicalAddress,
		 (unsigned long)cpuIndex, (unsigned long long)pc,
		 (unsigned long)_unmappedAccessCount];
	}
	[self logProcessorSnapshotForCPU:cpuIndex vcpu:vcpu pc:pc];
}

/// 打一份客户机处理器快照：通用寄存器 + PC 处那条指令的机器码。
/// 内核是线性装载在 0x80080000 的，PC 的低 32 位就是镜像内的偏移，所以只要拿到
/// 这 4 个字节，就能反汇编出到底哪条指令在访问坏地址。
- (void)logProcessorSnapshotForCPU:(NSUInteger)cpuIndex vcpu:(uint64_t)vcpu pc:(uint64_t)pc {
	uint64_t registers[31] = { 0 };
	for (uint32_t index = 0; index < 31; index++) {
		[_hypervisor getRegister:index value:&registers[index] forVCPU:vcpu];
	}
	uint64_t cpsr = 0;
	[_hypervisor getRegister:VLHypervisorRegisterCPSR value:&cpsr forVCPU:vcpu];
	NSUInteger serialCharacters = [_serial writtenCharacterCount];
	[VLStartupLog log:@"客户机快照：核 %lu PC=0x%llx CPSR=0x%llx x0=0x%llx x1=0x%llx x2=0x%llx "
					   @"x3=0x%llx x4=0x%llx x29=0x%llx x30=0x%llx，串口已输出 %lu 个字符",
	 (unsigned long)cpuIndex, (unsigned long long)pc, (unsigned long long)cpsr,
	 (unsigned long long)registers[0], (unsigned long long)registers[1],
	 (unsigned long long)registers[2], (unsigned long long)registers[3],
	 (unsigned long long)registers[4], (unsigned long long)registers[29],
	 (unsigned long long)registers[30], (unsigned long)serialCharacters];

	uint64_t candidates[3] = {
		pc & 0xFFFFFFFFu,
		pc - 0xFFFF800000000000ULL,
		pc - 0xFFFF000000000000ULL,
	};
	for (NSUInteger index = 0; index < 3; index++) {
		const uint8_t *code = [_guestMemory hostPointerForGuestAddress:candidates[index] length:16];
		if (code == NULL) {
			continue;
		}
		[VLStartupLog log:@"PC 处指令（按 0x%llx 读）：%02x %02x %02x %02x  %02x %02x %02x %02x  "
						   @"%02x %02x %02x %02x  %02x %02x %02x %02x",
		 (unsigned long long)candidates[index],
		 code[0], code[1], code[2], code[3], code[4], code[5], code[6], code[7],
		 code[8], code[9], code[10], code[11], code[12], code[13], code[14], code[15]];
	}
}

- (BOOL)writeValue:(uint64_t)value width:(uint32_t)width address:(uint64_t)address {
	if (width == 8) {
		BOOL low = [_deviceBus writeAddress:address width:4 value:(uint32_t)(value & 0xFFFFFFFF)];
		BOOL high = [_deviceBus writeAddress:address + 4 width:4 value:(uint32_t)(value >> 32)];
		return low && high;
	}
	return [_deviceBus writeAddress:address width:width value:(uint32_t)value];
}

- (BOOL)readValue:(uint64_t *)value width:(uint32_t)width address:(uint64_t)address {
	if (width == 8) {
		uint32_t low = 0;
		uint32_t high = 0;
		if (![_deviceBus readAddress:address width:4 value:&low] ||
			![_deviceBus readAddress:address + 4 width:4 value:&high]) {
			return NO;
		}
		*value = ((uint64_t)high << 32) | low;
		return YES;
	}
	uint32_t result = 0;
	if (![_deviceBus readAddress:address width:width value:&result]) {
		return NO;
	}
	*value = result;
	return YES;
}

- (BOOL)handleHypervisorCallForCPU:(NSUInteger)cpuIndex vcpu:(uint64_t)vcpu {
	uint64_t function = 0;
	[_hypervisor getRegister:0 value:&function forVCPU:vcpu];

	// PSCI 的 64 位变体就是在 32 位功能号上多了 bit30（0x8400000X → 0xC400000X）。
	// arm64 内核统一用 64 位变体（CPU_ON 实际是 0xC4000003），只认 0x8400000X
	// 会让次级核的 CPU_ON 落到「不支持」，日志里就是 psci: failed to boot CPU1 (-95)。
	if ((function & 0x40000000ULL) != 0) {
		function &= ~0x40000000ULL;
	}

	uint64_t result = VL_PSCI_RET_NOT_SUPPORTED;

	if (function == VL_PSCI_VERSION) {
		result = 0x00010001; // PSCI 1.1
	} else if (function == VL_PSCI_CPU_OFF) {
		[VLStartupLog log:@"客户机执行 CPU_OFF（%lu 号核下线）", (unsigned long)cpuIndex];
		// CPU_OFF 按规范不返回：这个核的线程就此结束、销毁自己的 vCPU。
		if (cpuIndex == 0) {
			_stopRequested = YES;
			[self exitAllProcessors];
			[self reportState:VLVirtualMachineStateStopped message:@"客户机已停止（CPU_OFF）"];
		}
		return NO;
	} else if (function == VL_PSCI_CPU_ON) {
		uint64_t mpidr = 0;
		uint64_t entry = 0;
		uint64_t contextID = 0;
		[_hypervisor getRegister:1 value:&mpidr forVCPU:vcpu];
		[_hypervisor getRegister:2 value:&entry forVCPU:vcpu];
		[_hypervisor getRegister:3 value:&contextID forVCPU:vcpu];
		result = [self startCPUWithMPIDR:mpidr entry:entry contextID:contextID];
	} else if (function == VL_PSCI_AFFINITY_INFO) {
		uint64_t mpidr = 0;
		[_hypervisor getRegister:1 value:&mpidr forVCPU:vcpu];
		result = [self affinityForMPIDR:mpidr];
	} else if (function == VL_PSCI_SYSTEM_OFF) {
		[VLStartupLog log:@"客户机请求关机"];
		_stopRequested = YES;
		[self exitAllProcessors];
		[self reportState:VLVirtualMachineStateStopped message:@"客户机已关机"];
		return NO;
	} else if (function == VL_PSCI_SYSTEM_RESET) {
		[VLStartupLog log:@"客户机请求重启"];
		_stopRequested = YES;
		[self exitAllProcessors];
		[self reportState:VLVirtualMachineStateStopped message:@"客户机请求重启：请重新启动虚拟机"];
		return NO;
	}

	[_hypervisor setRegister:0 value:result forVCPU:vcpu];
	// HVC 的返回地址按架构规定是「HVC 后面那条指令」，Hypervisor.framework 交出来的
	// PC 已经是它了，这里不能再 +4：多走一条会把 __arm_smccc_hvc 里的取 res 指针
	// （ldr x4, [sp]）整条跳过，内核随后拿 x4=0 去写结果，直接 NULL 解引用 panic。
	return YES;
}

/// PSCI CPU_ON：叫醒一个还没开机的核。MPIDR 的低 8 位就是设备树里 cpu@N 的 reg。
- (uint64_t)startCPUWithMPIDR:(uint64_t)mpidr entry:(uint64_t)entry contextID:(uint64_t)contextID {
	NSUInteger index = (NSUInteger)(mpidr & 0xFF);
	if (index >= _cpuCount) {
		return VL_PSCI_RET_INVALID_PARAMETERS;
	}

	// 这里不要求槽位的 vCPU 已经建好：内核在启动早期就会调 CPU_ON，比我们开线程还早。
	// 先把开机请求记下来，等那个核的线程建完 vCPU 自己会看到这个标志直接开机。
	[_startCondition lock];
	BOOL alreadyOn = _slots[index].startRequested || _slots[index].finished;
	if (!alreadyOn) {
		_slots[index].startPC = entry;
		_slots[index].startContextID = contextID;
		_slots[index].startRequested = YES;
		[_startCondition broadcast];
	}
	[_startCondition unlock];

	return alreadyOn ? VL_PSCI_RET_ALREADY_ON : 0;
}

/// AFFINITY_INFO：0 = 在线，1 = 离线。
- (uint64_t)affinityForMPIDR:(uint64_t)mpidr {
	NSUInteger index = (NSUInteger)(mpidr & 0xFF);
	if (index >= _cpuCount) {
		return VL_PSCI_RET_INVALID_PARAMETERS;
	}
	[_startCondition lock];
	BOOL online = _slots[index].created && _slots[index].startRequested && !_slots[index].finished;
	[_startCondition unlock];
	return online ? 0 : 1;
}

#pragma mark - 清理

- (void)teardown {
	if (_usageTimer != NULL) {
		dispatch_source_cancel(_usageTimer);
		_usageTimer = nil;
	}
	// vCPU 由各自的线程负责销毁（HVF 要求同线程），这里只回收公共资源。
	for (NSUInteger index = 0; index < VLMaximumCPUs; index++) {
		_slots[index].vcpu = 0;
		_slots[index].exitInfo = NULL;
	}
	if (_guestMemory != nil) {
		[_guestMemory deallocate];
		_guestMemory = nil;
	}
	[_hypervisor destroyVirtualMachine];
	_hypervisor = nil;
	_deviceBus = nil;
	_interruptController = nil;
	_serial = nil;
	_gpu = nil;
	_block = nil;
	_iso = nil;
	_input = nil;
	_net = nil;
	_console = nil;
	_pvPanic = nil;
	[_network stop];
	_network = nil;
}

#pragma mark - 回调

- (NSError *)errorWithMessage:(NSString *)message {
	return [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
							   code:3
						   userInfo:@{ NSLocalizedDescriptionKey : message }];
}

- (void)reportState:(VLVirtualMachineState)state message:(NSString *)message {
	_state = state;
	_statusMessage = [message copy];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf != nil) {
			[strongSelf.delegate virtualMachine:strongSelf didChangeState:state message:message];
		}
	});
}

- (void)reportFailure:(NSString *)message {
	[VLStartupLog log:@"虚拟化失败：%@", message];
	[self haltAllProcessors];
	[self reportState:VLVirtualMachineStateFailed message:message];
}

- (void)reportLine:(NSString *)line {
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf != nil) {
			[strongSelf.delegate virtualMachine:strongSelf didOutputLine:line];
		}
	});
}

/// 画面回调在 vCPU 线程上触发：做一次单帧背压，避免界面被刷爆。
- (void)deliverFrameWidth:(uint32_t)width height:(uint32_t)height data:(NSData *)data {
	if (__atomic_exchange_n(&_framePending, YES, __ATOMIC_RELAXED)) {
		return;
	}
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf != nil) {
			[strongSelf.delegate virtualMachine:strongSelf didUpdateFrameWidth:width height:height data:data];
			__atomic_store_n(&strongSelf->_framePending, NO, __ATOMIC_RELAXED);
		}
	});
}

#pragma mark - 触摸

/// App 里的比例坐标（0 – 1）换算成 virtio-input 的绝对坐标（0 – 32767）。
- (uint32_t)touchCoordinateForNormalized:(double)value {
	double clamped = value;
	if (clamped < 0) {
		clamped = 0;
	} else if (clamped > 1) {
		clamped = 1;
	}
	return (uint32_t)lround(clamped * 32767.0);
}

- (void)sendTouchBeganAtNormalizedX:(double)x y:(double)y {
	[_input touchDownAtX:[self touchCoordinateForNormalized:x]
					   y:[self touchCoordinateForNormalized:y]];
	_inputServicePending = YES;
}

- (void)sendTouchMovedToNormalizedX:(double)x y:(double)y {
	[_input touchMoveToX:[self touchCoordinateForNormalized:x]
					   y:[self touchCoordinateForNormalized:y]];
	_inputServicePending = YES;
}

- (void)sendTouchEnded {
	[_input touchUp];
	_inputServicePending = YES;
}

- (void)sendKeycode:(uint16_t)keycode pressed:(BOOL)pressed {
	[_input sendKeycode:keycode pressed:pressed];
	_inputServicePending = YES;
}

- (void)sendText:(NSString *)text {
	[_serial injectText:text];
	_inputServicePending = YES;
}

@end
