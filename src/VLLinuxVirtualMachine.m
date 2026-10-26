#import "VLLinuxVirtualMachine.h"

#import "VLHostCapabilities.h"

NSString *const VLLinuxVirtualMachineErrorDomain = @"com.twoyears666.virtuallinux.vm";

@implementation VLLinuxVirtualMachine

- (instancetype)init {
	self = [super init];
	if (self) {
		_memorySizeInMegabytes = 2048;
	}
	return self;
}

- (BOOL)startWithError:(NSError **)error {
	if (![VLHostCapabilities isSystemVersionSupported]) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
										 code:1
									 userInfo:@{NSLocalizedDescriptionKey:
										 @"当前系统不支持硬件虚拟化：16.4 起 XNU 移除了 Hypervisor 支持，本包只支持 14.0 – 16.3.1。"}];
		}
		return NO;
	}

	if (![VLHostCapabilities isHypervisorUsable]) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
										 code:2
									 userInfo:@{NSLocalizedDescriptionKey:
										 @"未找到 Hypervisor 运行时。需要把抽取并重签好的 Hypervisor.framework 放进 VirtualLinux.app/Frameworks/。"}];
		}
		return NO;
	}

	if (error != NULL) {
		*error = [NSError errorWithDomain:VLLinuxVirtualMachineErrorDomain
									 code:3
								 userInfo:@{NSLocalizedDescriptionKey:
									 @"Hypervisor 已就绪，但 Linux 客户机引导后端尚未接入（vCPU、内存映射、virtio 设备）。"}];
	}
	return NO;
}

- (void)stop {
}

@end
