// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLPVPanicDevice.h"

#import "VLStartupLog.h"

/// 能力位：bit0 支持 panic 事件，bit1 支持 crash loaded。
static const uint32_t VLPVPanicCapability = 0x3;
/// 事件位：bit0 = 已 panic，bit1 = crash 已加载。
static const uint32_t VLPVPanicEventPanicked = 0x1;
static const uint32_t VLPVPanicEventCrashLoaded = 0x2;

@implementation VLPVPanicDevice {
	BOOL _reported;
	uint64_t _baseAddress;
	uint32_t _regionSize;
}

- (uint64_t)baseAddress {
	return _baseAddress;
}

- (uint32_t)regionSize {
	return _regionSize;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x1000;
	}
	return self;
}

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	return offset == 0 ? VLPVPanicCapability : 0;
}

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	// 偏移 1 是事件寄存器；其余偏移忽略。
	if (offset != 1) {
		return;
	}
	if ((value & VLPVPanicEventPanicked) != 0 && !_reported) {
		_reported = YES;
		[VLStartupLog log:@"客户机通过 pvpanic 报告 panic（事件 0x%x）", value];
		if (self.panicHandler != nil) {
			self.panicHandler(@"客户机内核 panic");
		}
	}
	if ((value & VLPVPanicEventCrashLoaded) != 0) {
		[VLStartupLog log:@"客户机通过 pvpanic 报告 crash 已加载"];
	}
}

@end
