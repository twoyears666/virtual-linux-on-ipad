#import <Foundation/Foundation.h>

/// 极简用户态网络：给 virtio-net 提供出站 NAT，不依赖任何第三方库。
///
/// 客户机网络固定为 10.0.2.15/24：
/// - 网关 10.0.2.2：ARP 应答、ICMP echo、DHCP 服务器
/// - DNS 10.0.2.3：把查询转发给 8.8.8.8
/// - 其它地址的 TCP：用真实 socket 代理，客户机看到的是一次直连
///
/// 目前只做出站，端口转发（主机连进客户机）还没接。
@interface VLNetStack : NSObject

/// 给客户机的 MAC 地址（6 字节）。
@property (nonatomic, readonly, copy) NSData *macAddress;

/// 是否有待送进客户机的帧。
@property (nonatomic, readonly) BOOL hasOutboundFrames;

- (void)start;
- (void)stop;

/// 客户机发出的一帧以太网数据（在 vCPU 线程调用，内部转到网络队列处理）。
- (void)handleGuestFrame:(NSData *)frame;

/// 取一帧要送进客户机的数据（在 vCPU 线程调用），没有则返回 nil。
- (NSData *)dequeueOutboundFrame;

@end
