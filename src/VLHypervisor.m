// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLHypervisor.h"

#import <dlfcn.h>
#import <stdbool.h>

#import "VLStartupLog.h"

typedef int32_t (*VLCreateVirtualMachine)(void *);
typedef int32_t (*VLDestroyVirtualMachine)(void);
typedef int32_t (*VLMapMemory)(void *, uint64_t, size_t, uint32_t);
typedef int32_t (*VLUnmapMemory)(uint64_t, size_t);
typedef int32_t (*VLCreateVCPU)(uint64_t *, VLHypervisorExit **);
typedef int32_t (*VLCreateVCPUWithConfig)(uint64_t *, VLHypervisorExit **, void *);
typedef int32_t (*VLDestroyVCPU)(uint64_t);
typedef int32_t (*VLRunVCPU)(uint64_t);
typedef int32_t (*VLExitVCPUs)(uint64_t *, uint32_t);
typedef int32_t (*VLSetRegister)(uint64_t, uint32_t, uint64_t);
typedef int32_t (*VLGetRegister)(uint64_t, uint32_t, uint64_t *);
typedef int32_t (*VLSetPendingInterrupt)(uint64_t, uint32_t, bool);

@interface VLHypervisor ()

@property (nonatomic, assign, readwrite) BOOL available;
@property (nonatomic, copy, readwrite) NSString *failureReason;
@property (nonatomic, copy, readwrite) NSString *loadedPath;

@end

@implementation VLHypervisor {
	void *_handle;
	VLCreateVirtualMachine _createVM;
	VLDestroyVirtualMachine _destroyVM;
	VLMapMemory _mapMemory;
	VLUnmapMemory _unmapMemory;
	VLCreateVCPU _createVCPULegacy;
	VLCreateVCPUWithConfig _createVCPUWithConfig;
	VLDestroyVCPU _destroyVCPU;
	VLRunVCPU _runVCPU;
	VLExitVCPUs _exitVCPUs;
	VLSetRegister _setRegister;
	VLGetRegister _getRegister;
	VLSetPendingInterrupt _setPendingInterrupt;
}

+ (instancetype)shared {
	static VLHypervisor *instance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		instance = [[VLHypervisor alloc] init];
	});
	return instance;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		[self loadRuntime];
	}
	return self;
}

- (void)loadRuntime {
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];
	NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
	if (frameworks.length > 0) {
		[candidates addObject:[frameworks stringByAppendingPathComponent:@"Hypervisor.framework/Hypervisor"]];
	}
	[candidates addObjectsFromArray:@[
		@"/var/jb/usr/lib/libHypervisor.dylib",
		@"/usr/lib/libHypervisor.dylib",
		@"/System/Library/Frameworks/Hypervisor.framework/Hypervisor",
		@"/System/Library/PrivateFrameworks/Hypervisor.framework/Hypervisor",
	]];

	for (NSString *candidate in candidates) {
		if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
			continue;
		}
		void *handle = dlopen(candidate.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
		if (handle == NULL) {
			continue;
		}

		_createVM = (VLCreateVirtualMachine)dlsym(handle, "hv_vm_create");
		_destroyVM = (VLDestroyVirtualMachine)dlsym(handle, "hv_vm_destroy");
		_mapMemory = (VLMapMemory)dlsym(handle, "hv_vm_map");
		_unmapMemory = (VLUnmapMemory)dlsym(handle, "hv_vm_unmap");
		_createVCPULegacy = (VLCreateVCPU)dlsym(handle, "hv_vcpu_create");
		if (dlsym(handle, "hv_vcpu_config_create") != NULL) {
			// macOS 11 起 hv_vcpu_create 多了 config 参数。
			_createVCPUWithConfig = (VLCreateVCPUWithConfig)dlsym(handle, "hv_vcpu_create");
			_createVCPULegacy = NULL;
		} else {
			_createVCPUWithConfig = NULL;
		}
		_destroyVCPU = (VLDestroyVCPU)dlsym(handle, "hv_vcpu_destroy");
		_runVCPU = (VLRunVCPU)dlsym(handle, "hv_vcpu_run");
		_exitVCPUs = (VLExitVCPUs)dlsym(handle, "hv_vcpus_exit");
		_setRegister = (VLSetRegister)dlsym(handle, "hv_vcpu_set_reg");
		_getRegister = (VLGetRegister)dlsym(handle, "hv_vcpu_get_reg");
		_setPendingInterrupt = (VLSetPendingInterrupt)dlsym(handle, "hv_vcpu_set_pending_interrupt");

		BOOL complete = _createVM != NULL && _destroyVM != NULL && _mapMemory != NULL &&
			_unmapMemory != NULL && (_createVCPULegacy != NULL || _createVCPUWithConfig != NULL) &&
			_destroyVCPU != NULL && _runVCPU != NULL && _exitVCPUs != NULL &&
			_setRegister != NULL && _getRegister != NULL && _setPendingInterrupt != NULL;

		if (!complete) {
			[VLStartupLog log:@"Hypervisor 符号不全，跳过：%@", candidate];
			dlclose(handle);
			continue;
		}

		_handle = handle;
		self.loadedPath = candidate;
		self.available = YES;
		self.failureReason = nil;
		[VLStartupLog log:@"Hypervisor 已加载：%@", candidate];
		return;
	}

	self.available = NO;
	self.loadedPath = nil;
	self.failureReason = @"未找到可用的 Hypervisor 运行时，请把抽取并重签好的 Hypervisor.framework 放进 App 的 Frameworks/";
}

#pragma mark - 调用表

- (int32_t)createVirtualMachine {
	if (_createVM == NULL) {
		return -1;
	}
	// HV_VM_DEFAULT 在框架里是空配置。
	return _createVM(NULL);
}

- (int32_t)destroyVirtualMachine {
	if (_destroyVM == NULL) {
		return -1;
	}
	return _destroyVM();
}

- (int32_t)mapHostPointer:(void *)pointer
			 guestAddress:(uint64_t)guestAddress
					size:(size_t)size
				   flags:(VLHypervisorMemoryFlags)flags {
	if (_mapMemory == NULL) {
		return -1;
	}
	return _mapMemory(pointer, guestAddress, size, (uint32_t)flags);
}

- (int32_t)unmapGuestAddress:(uint64_t)guestAddress size:(size_t)size {
	if (_unmapMemory == NULL) {
		return -1;
	}
	return _unmapMemory(guestAddress, size);
}

- (int32_t)createVCPU:(uint64_t *)vcpu exitInfo:(VLHypervisorExit **)exitInfo {
	if (_createVCPUWithConfig != NULL) {
		return _createVCPUWithConfig(vcpu, exitInfo, NULL);
	}
	if (_createVCPULegacy != NULL) {
		return _createVCPULegacy(vcpu, exitInfo);
	}
	return -1;
}

- (int32_t)destroyVCPU:(uint64_t)vcpu {
	if (_destroyVCPU == NULL) {
		return -1;
	}
	return _destroyVCPU(vcpu);
}

- (int32_t)runVCPU:(uint64_t)vcpu {
	if (_runVCPU == NULL) {
		return -1;
	}
	return _runVCPU(vcpu);
}

- (int32_t)exitVCPUs:(const uint64_t *)vcpus count:(uint32_t)count {
	if (_exitVCPUs == NULL) {
		return -1;
	}
	// 框架的签名是非 const，这里是为了让调用方不用关心。
	return _exitVCPUs((uint64_t *)vcpus, count);
}

- (int32_t)setRegister:(uint32_t)reg value:(uint64_t)value forVCPU:(uint64_t)vcpu {
	if (_setRegister == NULL) {
		return -1;
	}
	return _setRegister(vcpu, reg, value);
}

- (int32_t)getRegister:(uint32_t)reg value:(uint64_t *)value forVCPU:(uint64_t)vcpu {
	if (_getRegister == NULL) {
		return -1;
	}
	return _getRegister(vcpu, reg, value);
}

- (int32_t)setPendingIRQ:(BOOL)pending forVCPU:(uint64_t)vcpu {
	if (_setPendingInterrupt == NULL) {
		return -1;
	}
	// HV_INTERRUPT_TYPE_IRQ = 0
	return _setPendingInterrupt(vcpu, 0, pending);
}

@end
