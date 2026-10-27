#import "VLVirtioMMIODevice.h"

/// virtio-input：对外表现为一块单点触摸屏，App 把手指位置换算成绝对坐标事件送给客户机。
/// 坐标范围 0 – 32767，左上角为原点。
@interface VLVirtioInput : VLVirtioMMIODevice

- (void)touchDownAtX:(uint32_t)x y:(uint32_t)y;
- (void)touchMoveToX:(uint32_t)x y:(uint32_t)y;
- (void)touchUp;

/// 把攒下的事件写进客户机已经挂上来的缓冲区。
/// 只能在 vCPU 线程调用：这里会写客户机内存并触发中断。
- (void)servicePendingEvents;

@end
