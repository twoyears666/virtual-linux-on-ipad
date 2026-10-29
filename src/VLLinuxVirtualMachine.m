#import "VLLinuxVirtualMachine.h"

#import <math.h>
#import <mach/mach_time.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "VLDeviceBus.h"
#import "VLDeviceTree.h"
#import "VLDiskBootVolume.h"
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
static const uint64_t VLISOBase = 0x0E000000;

// GIC 中断号：SPI 从 32 开始。PPI 编号按 arm64 的约定（设备树里 timer 节点写的是
// 13/14/11/10），EL1 虚拟定时器是 PPI 11——27 是 32 位 ARM 的编号，在 arm64 上没用。
static const uint32_t VLGPUInterrupt = 34;
static const uint32_t VLBlockInterrupt = 35;
static const uint32_t VLInputInterrupt = 36;
static const uint32_t VLNetInterrupt = 37;
static const uint32_t VLISOInterrupt = 38;
static const uint32_t VLPPIVirtualTimer = 11;

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
} VLVCPUSlot;


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
		_startCondition = [[NSCondition alloc] init];
		_deviceLock = [[NSRecursiveLock alloc] init];
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
	_systemRegisterTrapCount = 0;
	_trappedSystemRegisters = [NSMutableSet set];
	_mmioAccessCount = 0;
	_unmappedAccessCount = 0;
	_loggedUnmappedAddresses = [NSMutableSet set];
	[_startCondition lock];
	for (NSUInteger index = 0; index < VLMaximumCPUs; index++) {
		memset(&_slots[index], 0, sizeof(VLVCPUSlot));
	}
	[_startCondition unlock];
	[self parseDisplayResolution];
	[self reportState:VLVirtualMachineStateStarting message:@"创建虚拟硬件…"];

	NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(runVirtualMachine) object:nil];
	thread.name = @"VirtualLinux.vCPU0";
	thread.qualityOfService = NSQualityOfServiceUserInteractive;
	[thread start];
	return YES;
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
	_guestMemorySize = (uint64_t)MAX((NSUInteger)_configuration.memoryMB, (NSUInteger)128) * 1024ULL * 1024ULL;

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

	// 启动来源：系统盘里已经有装好的系统就优先用它（内核 / initrd / 命令行由安装器写在
	// 系统盘的 FAT 分区里），否则退回 ISO 里抽出来的那套安装内核。
	VLDiskBootVolume *bootVolume = [self openInstalledSystemBootVolume];
	NSData *diskKernel = [bootVolume dataForFileNamed:@"VMLINUZ" error:NULL];
	NSData *diskInitrd = [bootVolume dataForFileNamed:@"INITRD" error:NULL];

	// 内核：Image 直接按原始偏移装载，入口地址就是装载地址。
	uint64_t kernelAddress = VLGuestMemoryBase + VLKernelLoadOffset;
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
	[VLStartupLog log:@"启动来源：%@（内核 %ld 字节）",
		diskKernel.length > 0 ? @"系统盘里已装好的系统" : @"ISO 安装内核", (long)kernelSize];
	// 内核可能有十几 MB，装进客户机内存后立刻放掉。
	diskKernel = nil;

	uint64_t cursor = VLAlignUp(kernelAddress + (uint64_t)kernelSize, VLSegmentAlignment);

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

	// 从系统盘启动时用安装器写下的那份命令行（里面有真实的 root=），
	// 从 ISO 安装内核启动时才需要接上自动安装参数。
	BOOL hasPreseed = _configuration.preseedPath.length > 0 &&
		[NSFileManager.defaultManager fileExistsAtPath:_configuration.preseedPath];
	NSMutableString *bootArguments = [NSMutableString stringWithString:
		bootVolume.commandLine.length > 0
			? bootVolume.commandLine
			: @"console=ttyAMA0,115200 earlycon=pl011,0x09000000 loglevel=7 panic=1"];
	if (hasPreseed && bootVolume.commandLine.length == 0) {
		[bootArguments appendString:
			@" ip=dhcp auto=true priority=critical preseed/url=http://10.0.2.2/preseed.cfg"];
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
		[strongSelf->_startCondition lock];
		uint64_t vcpu = cpuIndex < strongSelf->_cpuCount ? strongSelf->_slots[cpuIndex].vcpu : 0;
		[strongSelf->_startCondition unlock];
		if (vcpu != 0) {
			[strongSelf->_hypervisor setPendingIRQ:asserted forVCPU:vcpu];
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
	// 自动安装的 preseed 由网关上的极简 HTTP 服务发给客户机（bootargs 里 preseed/url 指向它）。
	NSData *preseed = [NSData dataWithContentsOfFile:_configuration.preseedPath];
	if (preseed.length > 0) {
		[_network servePreseedContents:preseed];
		[VLStartupLog log:@"已准备 preseed 自动应答（%lu 字节）", (unsigned long)preseed.length];
	}
	_net = [[VLVirtioNet alloc] initWithBaseAddress:VLNetBase
									   guestMemory:_guestMemory
								   interruptNumber:VLNetInterrupt
							 interruptController:_interruptController
										   network:_network];
	[_deviceBus addDevice:_net];

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
				// 客户机虚拟定时器到期：把 PPI 27 挂到本核的 GIC 上（PPI 是核私有的）。
				[_interruptController setIRQPending:VLPPIVirtualTimer];
				continue;
			}
			if (reason == VLHypervisorExitReasonException) {
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
		return [self handleDataAbortSyndrome:syndrome
							 virtualAddress:exitInfo->info.exception.virtualAddress
							physicalAddress:exitInfo->info.exception.physicalAddress
										cpu:cpuIndex
									   vcpu:vcpu];
	}
	if (exceptionClass == 0x01) {
		// WFI/WFE 陷入：客户机在等中断。让出一点 CPU 再往前走，避免空转刷满。
		if (cpuIndex == 0 && _inputServicePending) {
			_inputServicePending = NO;
			[_input servicePendingEvents];
		}
		usleep(500);
		uint64_t pc = 0;
		[_hypervisor getRegister:VLHypervisorRegisterPC value:&pc forVCPU:vcpu];
		[_hypervisor setRegister:VLHypervisorRegisterPC value:pc + 4 forVCPU:vcpu];
		return YES;
	}
	if (exceptionClass == 0x16) {
		return [self handleHypervisorCallForCPU:cpuIndex vcpu:vcpu];
	}
	if (exceptionClass == 0x18) {
		// 系统寄存器陷入：Apple 的 Hypervisor 没实现这个寄存器（例如 ID_AA64ISAR2_EL1），
		// 内核一读就直接退出。按「该特性不存在」返回 0，然后跳过这条指令继续跑。
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
	// ISS 布局（EC=0x18）：bit0 方向（1=读 MRS，0=写 MSR），
	// [4:1] CRm，[8:5] Rt，[12:9] CRn，[16:13] Op1，[19:17] Op2，[21:20] Op0。
	uint32_t iss = (uint32_t)(syndrome & 0x1FFFFFF);
	BOOL isRead = (iss & 0x1) != 0;
	uint32_t crm = (iss >> 1) & 0xF;
	uint32_t rt = (iss >> 5) & 0x1F;
	uint32_t crn = (iss >> 9) & 0xF;
	uint32_t op1 = (iss >> 13) & 0xF;
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

	[_startCondition lock];
	BOOL created = _slots[index].created;
	BOOL alreadyOn = _slots[index].startRequested;
	if (created && !alreadyOn && !_slots[index].finished) {
		_slots[index].startPC = entry;
		_slots[index].startContextID = contextID;
		_slots[index].startRequested = YES;
		[_startCondition broadcast];
	}
	[_startCondition unlock];

	if (!created) {
		return VL_PSCI_RET_INVALID_PARAMETERS;
	}
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
