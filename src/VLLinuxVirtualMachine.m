#import "VLLinuxVirtualMachine.h"

#import <math.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "VLDeviceBus.h"
#import "VLDeviceTree.h"
#import "VLDiskImage.h"
#import "VLGuestMemory.h"
#import "VLHypervisor.h"
#import "VLInterruptController.h"
#import "VLNetStack.h"
#import "VLPL011Serial.h"
#import "VLStartupLog.h"
#import "VLVMConfiguration.h"
#import "VLVirtioBlock.h"
#import "VLVirtioGPU.h"
#import "VLVirtioInput.h"
#import "VLVirtioNet.h"

NSString *const VLLinuxVirtualMachineErrorDomain = @"com.twoyears666.virtuallinux.vm";

// 客户机物理地址规划（和 VLDeviceTree 里声明的一致）
static const uint64_t VLGuestMemoryBase = 0x80000000;
static const uint64_t VLKernelLoadOffset = 0x80000;
static const uint64_t VLPageSize = 0x1000;
static const uint64_t VLSegmentAlignment = 0x200000;
static const uint64_t VLUARTBase = 0x09000000;
static const uint64_t VLGICBase = 0x08000000;
static const uint64_t VLGPUBase = 0x0A000000;
static const uint64_t VLBlockBase = 0x0B000000;
static const uint64_t VLInputBase = 0x0C000000;
static const uint64_t VLNetBase = 0x0D000000;

// GIC 中断号：SPI 从 32 开始，PPI 27 是 EL1 虚拟定时器
static const uint32_t VLGPUInterrupt = 34;
static const uint32_t VLBlockInterrupt = 35;
static const uint32_t VLInputInterrupt = 36;
static const uint32_t VLNetInterrupt = 37;
static const uint32_t VLPPIVirtualTimer = 27;

/// HVC 调用（PSCI）里的功能号
#define VL_PSCI_VERSION 0x84000000ULL
#define VL_PSCI_CPU_OFF 0x84000002ULL
#define VL_PSCI_CPU_ON 0x84000003ULL
#define VL_PSCI_AFFINITY_INFO 0x84000004ULL
#define VL_PSCI_SYSTEM_OFF 0x84000008ULL
#define VL_PSCI_SYSTEM_RESET 0x84000009ULL
#define VL_PSCI_RET_NOT_SUPPORTED ((uint64_t)-1)

static uint64_t VLAlignUp(uint64_t value, uint64_t alignment) {
	return (value + alignment - 1) & ~(alignment - 1);
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
	VLNetStack *_network;

	uint64_t _vcpu;
	VLHypervisorExit *_exitInfo;
	NSUInteger _exitCount;
	BOOL _inputServicePending;

	BOOL _stopRequested;
	BOOL _framePending;
	uint64_t _guestMemorySize;
	uint32_t _displayWidth;
	uint32_t _displayHeight;
}

- (instancetype)initWithConfiguration:(VLVMConfiguration *)configuration {
	self = [super init];
	if (self) {
		_configuration = configuration;
		_state = VLVirtualMachineStateStopped;
		_statusMessage = @"未运行";
		_displayWidth = 1024;
		_displayHeight = 768;
	}
	return self;
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
	[self parseDisplayResolution];
	[self reportState:VLVirtualMachineStateStarting message:@"创建虚拟硬件…"];

	NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(runVirtualMachine) object:nil];
	thread.name = @"VirtualLinux.VCPU";
	thread.qualityOfService = NSQualityOfServiceUserInteractive;
	[thread start];
	return YES;
}

- (void)stop {
	_stopRequested = YES;
	if (_vcpu != 0) {
		uint64_t vcpu = _vcpu;
		[_hypervisor exitVCPUs:&vcpu count:1];
	}
	[self reportState:VLVirtualMachineStateStopped message:@"已停止"];
}

- (BOOL)isStopRequested {
	return _stopRequested;
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
		[self runProcessorLoop];
		[self teardown];
		if (_state != VLVirtualMachineStateFailed) {
			[self reportState:VLVirtualMachineStateStopped message:@"已停止"];
		}
	}
}

- (BOOL)setupEnvironmentWithError:(NSError **)error {
	_guestMemorySize = (uint64_t)MAX((NSUInteger)_configuration.memoryMB, (NSUInteger)128) * 1024ULL * 1024ULL;

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

	// 内核：Image 直接按原始偏移装载，入口地址就是装载地址。
	uint64_t kernelAddress = VLGuestMemoryBase + VLKernelLoadOffset;
	NSInteger kernelSize = [_guestMemory loadFileAtPath:_configuration.kernelPath
										 atGuestAddress:kernelAddress];
	if (kernelSize <= 0) {
		if (error != NULL) {
			*error = [self errorWithMessage:@"内核镜像读取失败"];
		}
		return NO;
	}

	uint64_t cursor = VLAlignUp(kernelAddress + (uint64_t)kernelSize, VLSegmentAlignment);

	// 设备树
	uint64_t deviceTreeAddress = cursor;
	cursor = VLAlignUp(deviceTreeAddress + 0x200000, VLSegmentAlignment);

	// initrd（可选）
	uint64_t initrdAddress = cursor;
	uint64_t initrdEnd = initrdAddress;
	if (_configuration.initrdPath.length > 0) {
		NSInteger initrdSize = [_guestMemory loadFileAtPath:_configuration.initrdPath
											  atGuestAddress:initrdAddress];
		if (initrdSize > 0) {
			initrdEnd = initrdAddress + (uint64_t)initrdSize;
			cursor = VLAlignUp(initrdEnd, VLPageSize);
		} else {
			initrdAddress = 0;
			initrdEnd = 0;
		}
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

	NSData *deviceTree = [VLDeviceTree deviceTreeWithMemoryBase:VLGuestMemoryBase
													memorySize:_guestMemorySize
												 bootArguments:@"console=ttyAMA0,115200 earlycon=pl011,0x09000000 loglevel=7 panic=1"
													 initrdStart:initrdAddress
													   initrdEnd:initrdEnd
														uartBase:VLUARTBase
														 gicBase:VLGICBase
														 gpuBase:VLGPUBase
													   blockBase:VLBlockBase
													   inputBase:VLInputBase
														 netBase:VLNetBase];
	if (![_guestMemory writeData:deviceTree atGuestAddress:deviceTreeAddress]) {
		if (error != NULL) {
			*error = [self errorWithMessage:@"设备树写入失败"];
		}
		return NO;
	}
	[VLStartupLog log:@"设备树已写入 0x%llx（%lu 字节），内核 0x%llx（%ld 字节）",
	 (unsigned long long)deviceTreeAddress, (unsigned long)deviceTree.length,
	 (unsigned long long)kernelAddress, (long)kernelSize];

	[self setupDevices];

	result = [_hypervisor createVCPU:&_vcpu exitInfo:&_exitInfo];
	if (result != 0) {
		if (error != NULL) {
			*error = [self errorWithMessage:[NSString stringWithFormat:@"hv_vcpu_create 失败（0x%x）", (unsigned)result]];
		}
		return NO;
	}

	// arm64 Linux 入口：PC = 内核装载地址，x0 = 设备树地址。
	[_hypervisor setRegister:VLHypervisorRegisterPC value:kernelAddress forVCPU:_vcpu];
	[_hypervisor setRegister:0 value:deviceTreeAddress forVCPU:_vcpu];
	[_hypervisor setRegister:1 value:0 forVCPU:_vcpu];
	[_hypervisor setRegister:2 value:0 forVCPU:_vcpu];
	[_hypervisor setRegister:3 value:0 forVCPU:_vcpu];
	// EL1h，屏蔽 D/A/I/F
	[_hypervisor setRegister:VLHypervisorRegisterCPSR value:0x3C5 forVCPU:_vcpu];

	[VLStartupLog log:@"vCPU 就绪：PC=0x%llx DTB=0x%llx 内存=%llu MB",
	 (unsigned long long)kernelAddress, (unsigned long long)deviceTreeAddress,
	 (unsigned long long)(_guestMemorySize / (1024ULL * 1024ULL))];
	return YES;
}

- (void)setupDevices {
	_deviceBus = [[VLDeviceBus alloc] init];

	_interruptController = [[VLInterruptController alloc] initWithBaseAddress:VLGICBase];
	__weak typeof(self) weakSelf = self;
	_interruptController.irqLineHandler = ^(BOOL asserted) {
		typeof(self) strongSelf = weakSelf;
		if (strongSelf != nil && strongSelf->_vcpu != 0) {
			[strongSelf->_hypervisor setPendingIRQ:asserted forVCPU:strongSelf->_vcpu];
		}
	};
	[_deviceBus addDevice:_interruptController];

	_serial = [[VLPL011Serial alloc] initWithBaseAddress:VLUARTBase];
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
	if (systemDisk.path.length > 0 &&
		[NSFileManager.defaultManager fileExistsAtPath:systemDisk.path]) {
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
}

- (void)runProcessorLoop {
	while (![self isStopRequested]) {
		// 每次退出都可能产生临时对象（画面数据），按迭代回收，避免长期运行内存一直涨。
		@autoreleasepool {
			int32_t result = [_hypervisor runVCPU:_vcpu];
			if (result != 0) {
				[self reportFailure:[NSString stringWithFormat:@"hv_vcpu_run 失败（0x%x）", (unsigned)result]];
				return;
			}
			if (_exitInfo == NULL) {
				[self reportFailure:@"Hypervisor 没有返回退出信息"];
				return;
			}

			uint32_t reason = _exitInfo->reason;
			// 第一次退出最能说明底层通不通，单独记一条，省得靠猜。
			if (_exitCount == 0) {
				_exitCount = 1;
				uint64_t pc = 0;
				[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:_vcpu];
				uint64_t syndrome = reason == VLHypervisorExitReasonException
					? _exitInfo->info.exception.syndrome
					: 0;
				[VLStartupLog log:@"vCPU 首次退出：原因=%u PC=0x%llx ESR=0x%llx",
				 reason, (unsigned long long)pc, (unsigned long long)syndrome];
			}
			if (reason == VLHypervisorExitReasonCanceled) {
				continue;
			}
			if (_inputServicePending) {
				_inputServicePending = NO;
				[_input servicePendingEvents];
			}
			// 网络栈攒下的下行帧要及时交给客户机，否则 TCP 会一直等。
			[_net serviceReceive];
			if (reason == VLHypervisorExitReasonVTimer) {
				// 客户机虚拟定时器到期：把 PPI 27 挂到 GIC 上。
				[_interruptController setIRQPending:VLPPIVirtualTimer];
				continue;
			}
			if (reason == VLHypervisorExitReasonException) {
				if (![self handleException]) {
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

- (BOOL)handleException {
	uint64_t syndrome = _exitInfo->info.exception.syndrome;
	uint64_t address = _exitInfo->info.exception.virtualAddress;
	uint32_t exceptionClass = (uint32_t)((syndrome >> 26) & 0x3F);

	if (exceptionClass == 0x24 || exceptionClass == 0x25) {
		return [self handleDataAbortSyndrome:syndrome address:address];
	}
	if (exceptionClass == 0x01) {
		// WFI/WFE 陷入：客户机在等中断。让出一点 CPU 再往前走，避免空转刷满。
		if (_inputServicePending) {
			_inputServicePending = NO;
			[_input servicePendingEvents];
		}
		usleep(500);
		uint64_t pc = 0;
		[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:_vcpu];
		[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:_vcpu];
		return YES;
	}
	if (exceptionClass == 0x16) {
		return [self handleHypervisorCall];
	}

	[self reportFailure:[NSString stringWithFormat:@"未处理的异常 EC=0x%x ESR=0x%llx",
						 exceptionClass, (unsigned long long)syndrome]];
	return NO;
}

- (BOOL)handleDataAbortSyndrome:(uint64_t)syndrome address:(uint64_t)address {
	BOOL instructionValid = ((syndrome >> 24) & 0x1) != 0;
	if (!instructionValid) {
		[self reportFailure:[NSString stringWithFormat:@"MMIO 访问无法解码 0x%llx", (unsigned long long)address]];
		return NO;
	}

	uint32_t widthCode = (uint32_t)((syndrome >> 22) & 0x3);
	uint32_t width = 1u << widthCode;
	BOOL isWrite = ((syndrome >> 6) & 0x1) != 0;
	uint32_t registerIndex = (uint32_t)((syndrome >> 16) & 0x1F);

	BOOL handled = NO;
	if (isWrite) {
		uint64_t value = 0;
		[_hypervisor getRegister:registerIndex value:&value forVCPU:_vcpu];
		handled = [self writeValue:value width:width address:address];
	} else {
		uint64_t value = 0;
		handled = [self readValue:&value width:width address:address];
		if (handled) {
			[_hypervisor setRegister:registerIndex value:value forVCPU:_vcpu];
		}
	}

	if (!handled) {
		[self reportFailure:[NSString stringWithFormat:@"访问了未实现的 MMIO 地址 0x%llx（%u 字节%@）",
							(unsigned long long)address, width, isWrite ? @"写" : @"读"]];
		return NO;
	}

	// 虚拟机停在触发异常的那条指令上，模拟完要自己往前推一条，否则会反复触发。
	uint64_t pc = 0;
	[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:_vcpu];
	[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:_vcpu];
	return YES;
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

- (BOOL)handleHypervisorCall {
	uint64_t function = 0;
	[_hypervisor getRegister:0 value:&function forVCPU:_vcpu];

	uint64_t result = VL_PSCI_RET_NOT_SUPPORTED;

	if (function == VL_PSCI_VERSION) {
		result = 0x00010001; // PSCI 1.1
	} else if (function == VL_PSCI_CPU_OFF) {
		// 单核客户机：把 CPU_OFF 当关机处理。
		[VLStartupLog log:@"客户机执行 CPU_OFF（单核不支持关核）"];
		_stopRequested = YES;
		[self reportState:VLVirtualMachineStateStopped message:@"客户机已停止（CPU_OFF）"];
		return NO;
	} else if (function == VL_PSCI_CPU_ON) {
		result = VL_PSCI_RET_NOT_SUPPORTED;
	} else if (function == VL_PSCI_AFFINITY_INFO) {
		result = 0; // ON
	} else if (function == VL_PSCI_SYSTEM_OFF) {
		[VLStartupLog log:@"客户机请求关机"];
		_stopRequested = YES;
		[self reportState:VLVirtualMachineStateStopped message:@"客户机已关机"];
		return NO;
	} else if (function == VL_PSCI_SYSTEM_RESET) {
		[VLStartupLog log:@"客户机请求重启"];
		_stopRequested = YES;
		[self reportState:VLVirtualMachineStateStopped message:@"客户机请求重启：请重新启动虚拟机"];
		return NO;
	}

	[_hypervisor setRegister:0 value:result forVCPU:_vcpu];
	uint64_t pc = 0;
	[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:_vcpu];
	[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:_vcpu];
	return YES;
}

#pragma mark - 清理

- (void)teardown {
	if (_vcpu != 0) {
		[_hypervisor destroyVCPU:_vcpu];
		_vcpu = 0;
	}
	_exitInfo = NULL;
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
	_input = nil;
	_net = nil;
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
	if (_framePending) {
		return;
	}
	_framePending = YES;
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf != nil) {
			[strongSelf.delegate virtualMachine:strongSelf didUpdateFrameWidth:width height:height data:data];
			strongSelf->_framePending = NO;
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

@end
