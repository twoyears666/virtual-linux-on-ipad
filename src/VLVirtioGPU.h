#import <Foundation/Foundation.h>

#import "VLDevice.h"

@class VLGuestMemory;
@class VLInterruptController;

/// virtio-mmio（legacy v1）上的 virtio-gpu 2D 扫描输出。
/// 只用 2D 资源 + scanout：客户机把画面画进显存，我们在 RESOURCE_FLUSH 时把像素取回来交给界面。
@interface VLVirtioGPU : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
					   displayWidth:(uint32_t)displayWidth
					  displayHeight:(uint32_t)displayHeight;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;

/// 客户机回报的初始分辨率，写进 GET_DISPLAY_INFO 的 pmodes[0]。
@property (nonatomic, readonly) uint32_t displayWidth;
@property (nonatomic, readonly) uint32_t displayHeight;

/// 一帧画面：BGRA 8888，行距紧密（width * 4）。
@property (nonatomic, copy) void (^frameHandler)(uint32_t width, uint32_t height, NSData *frame);

/// 每秒最多交给界面多少帧；0 表示不限。界面刷新再快也画不出来，限住能省下每帧的拷贝。
@property (nonatomic, assign) uint32_t maximumFramesPerSecond;

@end
