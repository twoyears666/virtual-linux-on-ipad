#import "VLNetStack.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "VLStartupLog.h"

// 客户机网络固定成这样，和 QEMU 的 user-mode 网络用同一套习惯地址。
#define VLNetGuestAddress 0x0A00020F     // 10.0.2.15
#define VLNetGatewayAddress 0x0A000202   // 10.0.2.2
#define VLNetDNSAddress 0x0A000203       // 10.0.2.3
#define VLNetBroadcastAddress 0xFFFFFFFF // 255.255.255.255
#define VLNetPublicDNSAddress 0x08080808  // 8.8.8.8
#define VLNetSubnetMask 0xFFFFFF00       // 10.0.2.0/24

#define VLNetEthernetHeaderLength 14
#define VLNetIPv4HeaderLength 20
#define VLNetUDPHeaderLength 8
#define VLNetTCPHeaderLength 20
#define VLNetMaximumSegmentSize 1400
#define VLNetReceiveWindow 65535
#define VLNetMaximumUDPFlows 64
#define VLNetUDPFlowIdleTimeout 60.0
#define VLNetHTTPRequestHeaderLimit 8192

#define VLNetTCPFlagFIN 0x01
#define VLNetTCPFlagSYN 0x02
#define VLNetTCPFlagRST 0x04
#define VLNetTCPFlagPSH 0x08
#define VLNetTCPFlagACK 0x10

static const uint8_t VLNetGuestMAC[6] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

static uint16_t VLReadBE16(const uint8_t *bytes) {
	return (uint16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
}

static uint32_t VLReadBE32(const uint8_t *bytes) {
	return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
		((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static void VLWriteBE16(uint8_t *bytes, uint16_t value) {
	bytes[0] = (uint8_t)((value >> 8) & 0xFF);
	bytes[1] = (uint8_t)(value & 0xFF);
}

static void VLWriteBE32(uint8_t *bytes, uint32_t value) {
	bytes[0] = (uint8_t)((value >> 24) & 0xFF);
	bytes[1] = (uint8_t)((value >> 16) & 0xFF);
	bytes[2] = (uint8_t)((value >> 8) & 0xFF);
	bytes[3] = (uint8_t)(value & 0xFF);
}

static uint32_t VLChecksumAdd(uint32_t sum, const uint8_t *data, NSUInteger length) {
	NSUInteger index = 0;
	for (; index + 1 < length; index += 2) {
		sum += ((uint32_t)data[index] << 8) | (uint32_t)data[index + 1];
	}
	if ((length & 1) != 0) {
		sum += (uint32_t)data[length - 1] << 8;
	}
	return sum;
}

static uint16_t VLChecksumFinish(uint32_t sum) {
	while ((sum >> 16) != 0) {
		sum = (sum & 0xFFFF) + (sum >> 16);
	}
	return (uint16_t)(~sum & 0xFFFF);
}

static uint16_t VLChecksum(const uint8_t *data, NSUInteger length) {
	return VLChecksumFinish(VLChecksumAdd(0, data, length));
}

static uint16_t VLTransportChecksum(uint32_t source,
									uint32_t destination,
									uint8_t protocol,
									const uint8_t *segment,
									NSUInteger length) {
	uint8_t pseudo[12] = { 0 };
	VLWriteBE32(pseudo, source);
	VLWriteBE32(pseudo + 4, destination);
	pseudo[9] = protocol;
	VLWriteBE16(pseudo + 10, (uint16_t)length);
	uint32_t sum = VLChecksumAdd(0, pseudo, sizeof(pseudo));
	sum = VLChecksumAdd(sum, segment, length);
	return VLChecksumFinish(sum);
}

static NSString *VLIPv4String(uint32_t address) {
	return [NSString stringWithFormat:@"%u.%u.%u.%u",
		(unsigned)((address >> 24) & 0xFF), (unsigned)((address >> 16) & 0xFF),
		(unsigned)((address >> 8) & 0xFF), (unsigned)(address & 0xFF)];
}

/// 在请求缓冲里找 HTTP 头结束位置（\r\n\r\n），返回头加基于它的偏移，找不到返回 -1。
static NSInteger VLFindHTTPHeaderEnd(NSData *data) {
	const uint8_t *bytes = data.bytes;
	NSUInteger length = data.length;
	if (length < 4) {
		return -1;
	}
	for (NSUInteger index = 0; index + 3 < length; index++) {
		if (bytes[index] == '\r' && bytes[index + 1] == '\n' &&
			bytes[index + 2] == '\r' && bytes[index + 3] == '\n') {
			return (NSInteger)(index + 4);
		}
	}
	return -1;
}

#pragma mark - 一条 TCP 代理连接

typedef NS_ENUM(NSInteger, VLNetTCPState) {
	VLNetTCPStateSynReceived = 0,
	VLNetTCPStateEstablished,
};

@interface VLNetTCPConnection : NSObject

@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) uint16_t guestPort;
@property (nonatomic, assign) uint32_t destinationAddress;
@property (nonatomic, assign) uint16_t destinationPort;
@property (nonatomic, assign) int socketFD;
@property (nonatomic, assign) uint32_t receiveNext;
@property (nonatomic, assign) uint32_t sendNext;
@property (nonatomic, assign) uint32_t sendUna;
@property (nonatomic, assign) uint32_t guestWindow;
@property (nonatomic, assign) VLNetTCPState state;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) BOOL hostClosed;
@property (nonatomic, assign) BOOL guestClosed;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL localHTTP;
@property (nonatomic, assign) BOOL httpResponseSent;
@property (nonatomic, strong) NSMutableData *outboundBuffer;
@property (nonatomic, strong) NSMutableData *inboundBuffer;
@property (nonatomic, strong) NSMutableData *httpRequestBuffer;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *unacknowledged;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_source_t writeSource;

@end

@implementation VLNetTCPConnection

- (instancetype)init {
	self = [super init];
	if (self) {
		_outboundBuffer = [NSMutableData data];
		_inboundBuffer = [NSMutableData data];
		_httpRequestBuffer = [NSMutableData data];
		_unacknowledged = [NSMutableArray array];
		_guestWindow = VLNetReceiveWindow;
		_socketFD = -1;
	}
	return self;
}

@end

#pragma mark - 一条 UDP 直连流

/// UDP 没有握手，这里按「客户机源端口 + 目的地址 + 目的端口」把一条会话
/// 映射到一个宿主机 socket 上，回包再按原路送回去。
@interface VLNetUDPFlow : NSObject

@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) uint16_t guestPort;
@property (nonatomic, assign) uint32_t destinationAddress;
@property (nonatomic, assign) uint16_t destinationPort;
@property (nonatomic, assign) int socketFD;
@property (nonatomic, assign) CFAbsoluteTime lastActivity;
@property (nonatomic, strong) dispatch_source_t readSource;

@end

@implementation VLNetUDPFlow

- (instancetype)init {
	self = [super init];
	if (self) {
		_socketFD = -1;
	}
	return self;
}

@end

#pragma mark - VLNetStack

@implementation VLNetStack {
	dispatch_queue_t _queue;
	dispatch_source_t _timer;
	NSMutableArray<NSData *> *_outbound;
	NSMutableDictionary<NSString *, VLNetTCPConnection *> *_connections;
	NSMutableDictionary<NSString *, VLNetUDPFlow *> *_udpFlows;
	NSMutableDictionary<NSNumber *, NSNumber *> *_pendingQueries;
	int _dnsSocket;
	dispatch_source_t _dnsSource;
	NSData *_preseedContents;
	BOOL _running;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_queue = dispatch_queue_create("VirtualLinux.NetStack", DISPATCH_QUEUE_SERIAL);
		_outbound = [NSMutableArray array];
		_connections = [NSMutableDictionary dictionary];
		_udpFlows = [NSMutableDictionary dictionary];
		_pendingQueries = [NSMutableDictionary dictionary];
		_dnsSocket = -1;
		_macAddress = [NSData dataWithBytes:VLNetGuestMAC length:sizeof(VLNetGuestMAC)];
	}
	return self;
}

- (BOOL)hasOutboundFrames {
	@synchronized (self) {
		return _outbound.count > 0;
	}
}

- (void)start {
	if (_running) {
		return;
	}
	_running = YES;
	[self openDNSSocket];

	__weak typeof(self) weakSelf = self;
	_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
	dispatch_source_set_timer(_timer,
							  dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
							  200 * NSEC_PER_MSEC,
							  20 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(_timer, ^{
		typeof(self) strongSelf = weakSelf;
		[strongSelf handleTimer];
	});
	dispatch_resume(_timer);
	[VLStartupLog log:@"virtio-net 用户态网络就绪：客户机 10.0.2.15，网关 10.0.2.2，DNS 10.0.2.3"];
}

- (void)stop {
	if (!_running) {
		return;
	}
	_running = NO;
	__weak typeof(self) weakSelf = self;
	dispatch_sync(_queue, ^{
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		if (strongSelf->_timer != nil) {
			dispatch_source_cancel(strongSelf->_timer);
			strongSelf->_timer = nil;
		}
		if (strongSelf->_dnsSource != nil) {
			dispatch_source_cancel(strongSelf->_dnsSource);
			strongSelf->_dnsSource = nil;
		}
		if (strongSelf->_dnsSocket >= 0) {
			close(strongSelf->_dnsSocket);
			strongSelf->_dnsSocket = -1;
		}
		for (NSString *key in strongSelf->_connections.allKeys) {
			[strongSelf closeConnection:strongSelf->_connections[key] reset:NO];
		}
		for (NSString *key in strongSelf->_udpFlows.allKeys) {
			[strongSelf closeUDPFlow:strongSelf->_udpFlows[key]];
		}
		[strongSelf->_pendingQueries removeAllObjects];
		@synchronized (strongSelf) {
			[strongSelf->_outbound removeAllObjects];
		}
		strongSelf->_preseedContents = nil;
	});
}

#pragma mark - 对外接口

- (void)servePreseedContents:(NSData *)contents {
	_preseedContents = [contents copy];
}

- (void)handleGuestFrame:(NSData *)frame {
	if (frame.length < VLNetEthernetHeaderLength) {
		return;
	}
	dispatch_async(_queue, ^{
		[self processGuestFrame:frame];
	});
}

- (NSData *)dequeueOutboundFrame {
	@synchronized (self) {
		if (_outbound.count == 0) {
			return nil;
		}
		NSData *frame = _outbound.firstObject;
		[_outbound removeObjectAtIndex:0];
		return frame;
	}
}

- (void)enqueueFrame:(NSData *)frame {
	@synchronized (self) {
		[_outbound addObject:frame];
	}
}

#pragma mark - 收帧分发

- (void)processGuestFrame:(NSData *)frame {
	const uint8_t *bytes = frame.bytes;
	NSUInteger length = frame.length;
	uint16_t etherType = VLReadBE16(bytes + 12);

	if (etherType == 0x0806) {
		[self handleARP:bytes + VLNetEthernetHeaderLength
				 length:length - VLNetEthernetHeaderLength];
		return;
	}
	if (etherType == 0x0800) {
		[self handleIPv4:bytes + VLNetEthernetHeaderLength
				  length:length - VLNetEthernetHeaderLength];
	}
}

- (void)handleARP:(const uint8_t *)data length:(NSUInteger)length {
	if (length < 28 || VLReadBE16(data + 6) != 1) {
		return;
	}
	uint32_t targetAddress = VLReadBE32(data + 24);
	if (targetAddress != VLNetGatewayAddress && targetAddress != VLNetDNSAddress) {
		return;
	}

	uint8_t reply[28] = { 0 };
	VLWriteBE16(reply, 1);
	VLWriteBE16(reply + 2, 0x0800);
	reply[4] = 6;
	reply[5] = 4;
	VLWriteBE16(reply + 6, 2);
	memcpy(reply + 8, _macAddress.bytes, 6);
	VLWriteBE32(reply + 14, targetAddress);
	memcpy(reply + 18, data + 8, 6);
	VLWriteBE32(reply + 24, VLReadBE32(data + 14));
	[self sendEthernetToGuest:reply length:sizeof(reply) etherType:0x0806];
}

- (void)handleIPv4:(const uint8_t *)data length:(NSUInteger)length {
	if (length < VLNetIPv4HeaderLength || (data[0] >> 4) != 4) {
		return;
	}
	NSUInteger headerLength = (NSUInteger)(data[0] & 0x0F) * 4;
	if (headerLength < VLNetIPv4HeaderLength || headerLength > length) {
		return;
	}
	NSUInteger totalLength = VLReadBE16(data + 2);
	if (totalLength < headerLength || totalLength > length) {
		totalLength = length;
	}
	// 分片不做：只处理 DF 或未分片的包。
	if ((VLReadBE16(data + 6) & 0x3FFF) != 0) {
		return;
	}

	uint32_t source = VLReadBE32(data + 12);
	uint32_t destination = VLReadBE32(data + 16);
	uint8_t protocol = data[9];
	const uint8_t *segment = data + headerLength;
	NSUInteger segmentLength = totalLength - headerLength;

	if (protocol == 1) {
		[self handleICMP:segment length:segmentLength source:source destination:destination];
	} else if (protocol == 17) {
		[self handleUDP:segment length:segmentLength source:source destination:destination];
	} else if (protocol == 6) {
		[self handleTCP:segment length:segmentLength source:source destination:destination];
	}
}

- (void)handleICMP:(const uint8_t *)data
			 length:(NSUInteger)length
			 source:(uint32_t)source
		destination:(uint32_t)destination {
	if (length < 8 || data[0] != 8 || destination != VLNetGatewayAddress) {
		return;
	}
	NSMutableData *payload = [NSMutableData dataWithBytes:data length:length];
	uint8_t *bytes = payload.mutableBytes;
	bytes[0] = 0;
	bytes[2] = 0;
	bytes[3] = 0;
	VLWriteBE16(bytes + 2, VLChecksum(bytes, length));
	[self sendIPv4From:destination to:source protocol:1 payload:payload];
}

- (void)handleUDP:(const uint8_t *)data
		   length:(NSUInteger)length
		   source:(uint32_t)source
	  destination:(uint32_t)destination {
	if (length < VLNetUDPHeaderLength) {
		return;
	}
	uint16_t sourcePort = VLReadBE16(data);
	uint16_t destinationPort = VLReadBE16(data + 2);
	NSUInteger udpLength = VLReadBE16(data + 4);
	if (udpLength < VLNetUDPHeaderLength || udpLength > length) {
		return;
	}
	const uint8_t *payload = data + VLNetUDPHeaderLength;
	NSUInteger payloadLength = udpLength - VLNetUDPHeaderLength;

	if (destinationPort == 67) {
		[self handleDHCP:payload length:payloadLength sourcePort:sourcePort];
		return;
	}
	if (destinationPort == 53 && destination == VLNetDNSAddress) {
		[self forwardDNSQuery:payload length:payloadLength sourcePort:sourcePort];
		return;
	}
	// 网关和同网段里没有别的机器，广播也不往外发，其余目的地址一律直连转发。
	if ((destination & VLNetSubnetMask) == (VLNetGatewayAddress & VLNetSubnetMask) ||
		destination == VLNetBroadcastAddress) {
		return;
	}
	[self forwardUDP:payload length:payloadLength guestPort:sourcePort address:destination port:destinationPort];
}

#pragma mark - DHCP

- (void)handleDHCP:(const uint8_t *)data length:(NSUInteger)length sourcePort:(uint16_t)sourcePort {
	if (length < 240) {
		return;
	}
	uint8_t messageType = 0;
	NSUInteger offset = 240;
	while (offset + 1 < length) {
		uint8_t option = data[offset];
		if (option == 255) {
			break;
		}
		uint8_t optionLength = data[offset + 1];
		if (offset + 2 + optionLength > length) {
			break;
		}
		if (option == 53 && optionLength >= 1) {
			messageType = data[offset + 2];
		}
		offset += 2 + optionLength;
	}
	// 只处理 DISCOVER(1) 与 REQUEST(3)。
	if (messageType != 1 && messageType != 3) {
		return;
	}

	uint8_t reply[240 + 64] = { 0 };
	reply[0] = 2;                 // BOOTREPLY
	reply[1] = 1;                 // 以太网
	reply[2] = 6;                 // MAC 长度
	memcpy(reply + 4, data + 4, 4);   // xid
	memcpy(reply + 10, data + 10, 2); // flags
	VLWriteBE32(reply + 16, VLNetGuestAddress);
	VLWriteBE32(reply + 20, VLNetGatewayAddress);
	memcpy(reply + 28, data + 28, 6); // chaddr
	VLWriteBE32(reply + 236, 0x63825363);

	NSUInteger cursor = 240;
	reply[cursor++] = 53;
	reply[cursor++] = 1;
	reply[cursor++] = messageType == 1 ? 2 : 5;
	reply[cursor++] = 54;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, VLNetGatewayAddress);
	cursor += 4;
	reply[cursor++] = 51;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, 86400);
	cursor += 4;
	reply[cursor++] = 1;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, 0xFFFFFF00);
	cursor += 4;
	reply[cursor++] = 3;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, VLNetGatewayAddress);
	cursor += 4;
	reply[cursor++] = 6;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, VLNetDNSAddress);
	cursor += 4;
	reply[cursor++] = 28;
	reply[cursor++] = 4;
	VLWriteBE32(reply + cursor, VLNetBroadcastAddress);
	cursor += 4;
	reply[cursor++] = 255;

	NSMutableData *payload = [NSMutableData dataWithBytes:reply length:cursor];
	[self sendUDPFrom:VLNetGatewayAddress
				   to:VLNetBroadcastAddress
		   sourcePort:67
	  destinationPort:68
			  payload:payload];
	[VLStartupLog log:@"网络：DHCP %@ 客户机", messageType == 1 ? @"OFFER" : @"ACK"];
}

#pragma mark - DNS

- (void)openDNSSocket {
	int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
	if (descriptor < 0) {
		[VLStartupLog log:@"网络：DNS 转发 socket 创建失败（%s）", strerror(errno)];
		return;
	}
	fcntl(descriptor, F_SETFL, O_NONBLOCK);
	_dnsSocket = descriptor;

	__weak typeof(self) weakSelf = self;
	_dnsSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, _queue);
	dispatch_source_set_event_handler(_dnsSource, ^{
		typeof(self) strongSelf = weakSelf;
		[strongSelf readDNSResponse];
	});
	dispatch_resume(_dnsSource);
}

- (void)forwardDNSQuery:(const uint8_t *)data length:(NSUInteger)length sourcePort:(uint16_t)sourcePort {
	if (_dnsSocket < 0 || length < 12) {
		return;
	}
	struct sockaddr_in address = { 0 };
	address.sin_family = AF_INET;
	address.sin_port = htons(53);
	address.sin_addr.s_addr = htonl(VLNetPublicDNSAddress);
	if (sendto(_dnsSocket, data, length, 0, (struct sockaddr *)&address, sizeof(address)) < 0) {
		return;
	}
	_pendingQueries[@(VLReadBE16(data))] = @(sourcePort);
}

- (void)readDNSResponse {
	uint8_t buffer[2048];
	for (;;) {
		ssize_t count = recv(_dnsSocket, buffer, sizeof(buffer), 0);
		if (count < 12) {
			return;
		}
		NSNumber *key = @(VLReadBE16(buffer));
		NSNumber *port = _pendingQueries[key];
		if (port == nil) {
			continue;
		}
		[_pendingQueries removeObjectForKey:key];
		NSData *payload = [NSData dataWithBytes:buffer length:(NSUInteger)count];
		[self sendUDPFrom:VLNetDNSAddress
					   to:VLNetGuestAddress
			   sourcePort:53
		  destinationPort:(uint16_t)port.unsignedIntValue
				  payload:payload];
	}
}

#pragma mark - UDP 直连

- (void)forwardUDP:(const uint8_t *)payload
			length:(NSUInteger)length
		 guestPort:(uint16_t)guestPort
		   address:(uint32_t)address
			  port:(uint16_t)port {
	VLNetUDPFlow *flow = [self udpFlowForGuestPort:guestPort address:address port:port];
	if (flow == nil) {
		return;
	}
	flow.lastActivity = CFAbsoluteTimeGetCurrent();

	struct sockaddr_in remote = { 0 };
	remote.sin_family = AF_INET;
	remote.sin_port = htons(port);
	remote.sin_addr.s_addr = htonl(address);
	if (sendto(flow.socketFD, payload, length, 0, (struct sockaddr *)&remote, sizeof(remote)) < 0) {
		[VLStartupLog log:@"网络：UDP 发往 %@:%u 失败（%s）",
			VLIPv4String(address), (unsigned)port, strerror(errno)];
	}
}

- (VLNetUDPFlow *)udpFlowForGuestPort:(uint16_t)guestPort
							  address:(uint32_t)address
								 port:(uint16_t)port {
	NSString *key = [NSString stringWithFormat:@"%u-%08x-%u", guestPort, address, port];
	VLNetUDPFlow *flow = _udpFlows[key];
	if (flow != nil) {
		return flow;
	}

	// 流表满了先关最久没动静的那条，UDP 本来就是可以随时丢弃的。
	if (_udpFlows.count >= VLNetMaximumUDPFlows) {
		VLNetUDPFlow *oldest = nil;
		for (VLNetUDPFlow *candidate in _udpFlows.allValues) {
			if (oldest == nil || candidate.lastActivity < oldest.lastActivity) {
				oldest = candidate;
			}
		}
		if (oldest != nil) {
			[self closeUDPFlow:oldest];
		}
	}

	int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
	if (descriptor < 0) {
		[VLStartupLog log:@"网络：UDP socket 创建失败（%s）", strerror(errno)];
		return nil;
	}
	fcntl(descriptor, F_SETFL, O_NONBLOCK);

	flow = [[VLNetUDPFlow alloc] init];
	flow.key = key;
	flow.guestPort = guestPort;
	flow.destinationAddress = address;
	flow.destinationPort = port;
	flow.socketFD = descriptor;
	flow.lastActivity = CFAbsoluteTimeGetCurrent();
	_udpFlows[key] = flow;

	__weak typeof(self) weakSelf = self;
	__weak VLNetUDPFlow *weakFlow = flow;
	flow.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, _queue);
	dispatch_source_set_event_handler(flow.readSource, ^{
		typeof(self) strongSelf = weakSelf;
		VLNetUDPFlow *strongFlow = weakFlow;
		if (strongSelf == nil || strongFlow == nil) {
			return;
		}
		[strongSelf readUDPFlow:strongFlow];
	});
	dispatch_resume(flow.readSource);
	return flow;
}

- (void)readUDPFlow:(VLNetUDPFlow *)flow {
	if (flow.socketFD < 0) {
		return;
	}
	uint8_t buffer[2048];
	for (;;) {
		struct sockaddr_in remote = { 0 };
		socklen_t remoteLength = sizeof(remote);
		ssize_t count = recvfrom(flow.socketFD, buffer, sizeof(buffer), 0,
								 (struct sockaddr *)&remote, &remoteLength);
		if (count == 0) {
			return;
		}
		if (count < 0) {
			if (errno == EINTR) {
				continue;
			}
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				return;
			}
			// 对端回了 ICMP 端口不可达之类，这条流就没用了。
			[self closeUDPFlow:flow];
			return;
		}

		flow.lastActivity = CFAbsoluteTimeGetCurrent();
		uint16_t sourcePort = flow.destinationPort;
		if (remote.sin_family == AF_INET) {
			sourcePort = ntohs(remote.sin_port);
		}
		NSData *payload = [NSData dataWithBytes:buffer length:(NSUInteger)count];
		[self sendUDPFrom:flow.destinationAddress
					   to:VLNetGuestAddress
			   sourcePort:sourcePort
		  destinationPort:flow.guestPort
				  payload:payload];
	}
}

- (void)closeUDPFlow:(VLNetUDPFlow *)flow {
	if (flow == nil) {
		return;
	}
	if (flow.readSource != nil) {
		dispatch_source_cancel(flow.readSource);
		flow.readSource = nil;
	}
	if (flow.socketFD >= 0) {
		close(flow.socketFD);
		flow.socketFD = -1;
	}
	if (flow.key.length > 0) {
		[_udpFlows removeObjectForKey:flow.key];
	}
}

#pragma mark - TCP

- (void)handleTCP:(const uint8_t *)data
		   length:(NSUInteger)length
		   source:(uint32_t)source
	  destination:(uint32_t)destination {
	if (length < VLNetTCPHeaderLength) {
		return;
	}
	uint16_t sourcePort = VLReadBE16(data);
	uint16_t destinationPort = VLReadBE16(data + 2);
	uint32_t sequence = VLReadBE32(data + 4);
	uint32_t acknowledgement = VLReadBE32(data + 8);
	NSUInteger headerLength = (NSUInteger)(data[12] >> 4) * 4;
	if (headerLength < VLNetTCPHeaderLength || headerLength > length) {
		headerLength = VLNetTCPHeaderLength;
	}
	uint8_t flags = data[13];
	uint16_t window = VLReadBE16(data + 14);
	const uint8_t *payload = data + headerLength;
	NSUInteger payloadLength = length - headerLength;

	NSString *key = [NSString stringWithFormat:@"%u-%08x-%u", sourcePort, destination, destinationPort];
	VLNetTCPConnection *connection = _connections[key];

	if ((flags & VLNetTCPFlagRST) != 0) {
		if (connection != nil) {
			[self closeConnection:connection reset:NO];
		}
		return;
	}

	if ((flags & VLNetTCPFlagSYN) != 0) {
		if (connection != nil) {
			return;
		}
		connection = [[VLNetTCPConnection alloc] init];
		connection.key = key;
		connection.guestPort = sourcePort;
		connection.destinationAddress = destination;
		connection.destinationPort = destinationPort;
		connection.receiveNext = sequence + 1;
		connection.sendNext = 0x10000 + (arc4random() & 0xFFFF);
		connection.sendUna = connection.sendNext;
		connection.guestWindow = window > 0 ? window : VLNetReceiveWindow;
		connection.state = VLNetTCPStateSynReceived;
		// 网关 80 端口的 preseed 请求由本栈自己应答，不往真实 socket 转发。
		if (destination == VLNetGatewayAddress && destinationPort == 80 &&
			_preseedContents != nil) {
			connection.localHTTP = YES;
		}
		_connections[key] = connection;

		[self sendTCPForConnection:connection
							 flags:(VLNetTCPFlagSYN | VLNetTCPFlagACK)
						   payload:nil];
		if (!connection.localHTTP) {
			[self openSocketForConnection:connection];
		}
		return;
	}

	if (connection == nil) {
		// 没有握手就来数据，直接回 RST。
		[self sendTCPFrom:destination
					   to:source
			   sourcePort:destinationPort
		  destinationPort:sourcePort
				 sequence:acknowledgement
		acknowledgement:sequence + (uint32_t)payloadLength
					flags:VLNetTCPFlagRST
				  payload:nil];
		return;
	}

	if ((flags & VLNetTCPFlagACK) != 0) {
		[self updateConnection:connection
			   acknowledgement:acknowledgement
						window:window];
	}

	if (payloadLength > 0) {
		if (sequence == connection.receiveNext) {
			if (connection.localHTTP) {
				[connection.httpRequestBuffer appendBytes:payload length:payloadLength];
				connection.receiveNext += (uint32_t)payloadLength;
				[self respondToLocalHTTPConnection:connection];
			} else {
				[connection.outboundBuffer appendBytes:payload length:payloadLength];
				connection.receiveNext += (uint32_t)payloadLength;
				[self flushOutboundBuffer:connection];
			}
		}
		// 乱序或重传都不缓存，只回 ACK，让客户机自己重发。
	}

	if ((flags & VLNetTCPFlagFIN) != 0) {
		connection.receiveNext += 1;
		connection.guestClosed = YES;
		if (connection.socketFD >= 0) {
			shutdown(connection.socketFD, SHUT_WR);
		}
		[self sendTCPForConnection:connection
							 flags:(VLNetTCPFlagFIN | VLNetTCPFlagACK)
						   payload:nil];
		if (connection.hostClosed) {
			[self closeConnection:connection reset:NO];
			return;
		}
	}

	[self sendTCPForConnection:connection flags:VLNetTCPFlagACK payload:nil];
}

#pragma mark - 本地 HTTP

/// 请求数据累积到出现完整请求头（\r\n\r\n）后，回一份 preseed.cfg 并主动关闭。
- (void)respondToLocalHTTPConnection:(VLNetTCPConnection *)connection {
	if (connection.httpResponseSent || connection.finished) {
		return;
	}
	NSInteger headerEnd = VLFindHTTPHeaderEnd(connection.httpRequestBuffer);
	if (headerEnd < 0) {
		// 头还没收全；超过上限就按 404 处理，免得一直挂着。
		if (connection.httpRequestBuffer.length > VLNetHTTPRequestHeaderLimit) {
			[self sendLocalHTTPResponseForConnection:connection notFound:YES];
		}
		return;
	}
	[self sendLocalHTTPResponseForConnection:connection notFound:(_preseedContents == nil)];
}

/// 按 HTTP/1.0 组一份响应，分 MSS 段发出，再补一个 FIN；只在连接上发一次。
- (void)sendLocalHTTPResponseForConnection:(VLNetTCPConnection *)connection notFound:(BOOL)notFound {
	if (connection.httpResponseSent || connection.finished) {
		return;
	}
	connection.httpResponseSent = YES;

	NSData *contents = notFound ? [NSData data] : _preseedContents;
	NSString *head = notFound
		? @"HTTP/1.0 404 Not Found\r\n"
		   "Content-Length: 0\r\n"
		   "Content-Type: text/plain\r\n"
		   "Connection: close\r\n\r\n"
		: [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\n"
			"Content-Length: %llu\r\n"
			"Content-Type: text/plain\r\n"
			"Connection: close\r\n\r\n",
			(unsigned long long)contents.length];

	NSMutableData *response = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
	[response appendData:contents];

	NSUInteger offset = 0;
	while (offset < response.length) {
		NSUInteger chunk = MIN(response.length - offset, (NSUInteger)VLNetMaximumSegmentSize);
		NSData *part = [response subdataWithRange:NSMakeRange(offset, chunk)];
		[self sendTCPForConnection:connection
							 flags:(VLNetTCPFlagACK | VLNetTCPFlagPSH)
						   payload:part];
		offset += chunk;
	}

	connection.hostClosed = YES;
	[self sendTCPForConnection:connection
						 flags:(VLNetTCPFlagFIN | VLNetTCPFlagACK)
					   payload:nil];

	if (!notFound) {
		[VLStartupLog log:@"网络：已向客户机发送 preseed（%llu 字节）",
			(unsigned long long)contents.length];
	}
}

- (void)openSocketForConnection:(VLNetTCPConnection *)connection {
	int descriptor = socket(AF_INET, SOCK_STREAM, 0);
	if (descriptor < 0) {
		[self closeConnection:connection reset:YES];
		return;
	}
	int enabled = 1;
	setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
	fcntl(descriptor, F_SETFL, O_NONBLOCK);
	connection.socketFD = descriptor;

	struct sockaddr_in address = { 0 };
	address.sin_family = AF_INET;
	address.sin_port = htons(connection.destinationPort);
	address.sin_addr.s_addr = htonl(connection.destinationAddress);

	__weak typeof(self) weakSelf = self;
	int result = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
	if (result == 0) {
		[self connectionDidConnect:connection];
		return;
	}
	if (errno != EINPROGRESS) {
		[VLStartupLog log:@"网络：连接 %@:%u 失败（%s）",
			VLIPv4String(connection.destinationAddress), connection.destinationPort, strerror(errno)];
		[self closeConnection:connection reset:YES];
		return;
	}

	connection.writeSource =
		dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)descriptor, 0, _queue);
	dispatch_source_set_event_handler(connection.writeSource, ^{
		typeof(self) strongSelf = weakSelf;
		[strongSelf connectionDidBecomeWritable:connection];
	});
	dispatch_resume(connection.writeSource);
}

- (void)connectionDidBecomeWritable:(VLNetTCPConnection *)connection {
	if (connection.finished) {
		return;
	}
	int error = 0;
	socklen_t errorSize = sizeof(error);
	if (getsockopt(connection.socketFD, SOL_SOCKET, SO_ERROR, &error, &errorSize) < 0 || error != 0) {
		[VLStartupLog log:@"网络：连接 %@:%u 失败（%s）",
			VLIPv4String(connection.destinationAddress), connection.destinationPort, strerror(error)];
		[self closeConnection:connection reset:YES];
		return;
	}
	[self cancelWriteSource:connection];
	[self connectionDidConnect:connection];
}

- (void)connectionDidConnect:(VLNetTCPConnection *)connection {
	if (connection.finished) {
		return;
	}
	connection.connected = YES;
	connection.state = VLNetTCPStateEstablished;
	[VLStartupLog log:@"网络：TCP 已连上 %@:%u",
		VLIPv4String(connection.destinationAddress), connection.destinationPort];

	__weak typeof(self) weakSelf = self;
	connection.readSource =
		dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)connection.socketFD, 0, _queue);
	dispatch_source_set_event_handler(connection.readSource, ^{
		typeof(self) strongSelf = weakSelf;
		[strongSelf readFromConnection:connection];
	});
	dispatch_resume(connection.readSource);

	[self sendTCPForConnection:connection flags:VLNetTCPFlagACK payload:nil];
}

- (void)readFromConnection:(VLNetTCPConnection *)connection {
	if (connection.finished) {
		return;
	}
	uint8_t buffer[32768];
	for (;;) {
		ssize_t count = recv(connection.socketFD, buffer, sizeof(buffer), 0);
		if (count > 0) {
			[connection.inboundBuffer appendBytes:buffer length:(NSUInteger)count];
			continue;
		}
		if (count == 0) {
			connection.hostClosed = YES;
			break;
		}
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			break;
		}
		[self closeConnection:connection reset:YES];
		return;
	}

	[self flushInboundBuffer:connection];

	if (connection.hostClosed && !connection.finished) {
		[self sendTCPForConnection:connection
							 flags:(VLNetTCPFlagFIN | VLNetTCPFlagACK)
						   payload:nil];
		if (connection.guestClosed) {
			[self closeConnection:connection reset:NO];
		}
	}
}

- (void)flushInboundBuffer:(VLNetTCPConnection *)connection {
	if (!connection.connected || connection.finished) {
		return;
	}
	while (connection.inboundBuffer.length > 0) {
		uint32_t outstanding = connection.sendNext - connection.sendUna;
		if (outstanding >= connection.guestWindow) {
			return;
		}
		NSUInteger chunk = MIN(connection.inboundBuffer.length, (NSUInteger)VLNetMaximumSegmentSize);
		NSUInteger space = connection.guestWindow - outstanding;
		if (chunk > space) {
			chunk = space;
		}
		NSData *part = [connection.inboundBuffer subdataWithRange:NSMakeRange(0, chunk)];
		[connection.inboundBuffer replaceBytesInRange:NSMakeRange(0, chunk) withBytes:NULL length:0];
		[self sendTCPForConnection:connection
							 flags:(VLNetTCPFlagACK | VLNetTCPFlagPSH)
						   payload:part];
	}
}

- (void)flushOutboundBuffer:(VLNetTCPConnection *)connection {
	if (!connection.connected || connection.finished) {
		return;
	}
	while (connection.outboundBuffer.length > 0) {
		ssize_t written = send(connection.socketFD,
							   connection.outboundBuffer.bytes,
							   connection.outboundBuffer.length,
							   0);
		if (written > 0) {
			[connection.outboundBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)written)
												 withBytes:NULL
												   length:0];
			continue;
		}
		if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			[self resumeWriteSourceForConnection:connection];
			return;
		}
		[self closeConnection:connection reset:YES];
		return;
	}
}

- (void)resumeWriteSourceForConnection:(VLNetTCPConnection *)connection {
	if (connection.writeSource != nil) {
		return;
	}
	__weak typeof(self) weakSelf = self;
	connection.writeSource =
		dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)connection.socketFD, 0, _queue);
	dispatch_source_set_event_handler(connection.writeSource, ^{
		typeof(self) strongSelf = weakSelf;
		[strongSelf cancelWriteSource:connection];
		[strongSelf flushOutboundBuffer:connection];
	});
	dispatch_resume(connection.writeSource);
}

- (void)cancelWriteSource:(VLNetTCPConnection *)connection {
	if (connection.writeSource != nil) {
		dispatch_source_cancel(connection.writeSource);
		connection.writeSource = nil;
	}
}

- (void)updateConnection:(VLNetTCPConnection *)connection
		 acknowledgement:(uint32_t)acknowledgement
				  window:(uint16_t)window {
	if ((int32_t)(acknowledgement - connection.sendUna) > 0) {
		connection.sendUna = acknowledgement;
	}
	if (window > 0) {
		connection.guestWindow = window;
	}
	while (connection.unacknowledged.count > 0) {
		NSMutableDictionary *entry = connection.unacknowledged.firstObject;
		uint32_t end = [entry[@"sequence"] unsignedIntValue] + [entry[@"advance"] unsignedIntValue];
		if ((int32_t)(connection.sendUna - end) < 0) {
			break;
		}
		[connection.unacknowledged removeObjectAtIndex:0];
	}
	if (connection.state == VLNetTCPStateSynReceived) {
		connection.state = VLNetTCPStateEstablished;
	}
	[self flushInboundBuffer:connection];
}

- (void)sendTCPForConnection:(VLNetTCPConnection *)connection
					   flags:(uint8_t)flags
					 payload:(NSData *)payload {
	uint32_t sequence = connection.sendNext;
	[self sendTCPFrom:connection.destinationAddress
				   to:VLNetGuestAddress
		   sourcePort:connection.destinationPort
	  destinationPort:connection.guestPort
			 sequence:sequence
	  acknowledgement:connection.receiveNext
				flags:flags
			  payload:payload];

	uint32_t advance = (uint32_t)payload.length;
	if ((flags & (VLNetTCPFlagSYN | VLNetTCPFlagFIN)) != 0) {
		advance += 1;
	}
	connection.sendNext += advance;
	if (advance > 0) {
		[connection.unacknowledged addObject:[@{
			@"sequence": @(sequence),
			@"flags": @(flags),
			@"payload": payload ?: [NSData data],
			@"advance": @(advance),
			@"time": @(CFAbsoluteTimeGetCurrent()),
		} mutableCopy]];
	}
}

- (void)closeConnection:(VLNetTCPConnection *)connection reset:(BOOL)reset {
	if (connection.finished) {
		return;
	}
	connection.finished = YES;
	if (reset) {
		[self sendTCPForConnection:connection
							 flags:VLNetTCPFlagRST
						   payload:nil];
	}
	if (connection.readSource != nil) {
		dispatch_source_cancel(connection.readSource);
		connection.readSource = nil;
	}
	[self cancelWriteSource:connection];
	if (connection.socketFD >= 0) {
		close(connection.socketFD);
		connection.socketFD = -1;
	}
	if (connection.key.length > 0) {
		[_connections removeObjectForKey:connection.key];
	}
}

#pragma mark - 定时器

- (void)handleTimer {
	for (NSString *key in _connections.allKeys) {
		VLNetTCPConnection *connection = _connections[key];
		if (connection.unacknowledged.count == 0) {
			[self flushInboundBuffer:connection];
			continue;
		}
		NSMutableDictionary *entry = connection.unacknowledged.firstObject;
		CFAbsoluteTime sent = [entry[@"time"] doubleValue];
		if (CFAbsoluteTimeGetCurrent() - sent < 0.3) {
			continue;
		}
		if ([entry[@"retries"] unsignedIntegerValue] >= 6) {
			[VLStartupLog log:@"网络：重传次数超限，放弃 %@:%u",
				VLIPv4String(connection.destinationAddress), connection.destinationPort];
			[self closeConnection:connection reset:YES];
			continue;
		}
		entry[@"time"] = @(CFAbsoluteTimeGetCurrent());
		entry[@"retries"] = @([entry[@"retries"] unsignedIntegerValue] + 1);
		[self sendTCPFrom:connection.destinationAddress
					   to:VLNetGuestAddress
			   sourcePort:connection.destinationPort
		  destinationPort:connection.guestPort
				 sequence:[entry[@"sequence"] unsignedIntValue]
		acknowledgement:connection.receiveNext
					flags:[entry[@"flags"] unsignedCharValue]
				  payload:entry[@"payload"]];
	}

	// UDP 没有关闭握手，长时间没流量就直接回收，免得 socket 一直挂着。
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	for (NSString *key in _udpFlows.allKeys) {
		VLNetUDPFlow *flow = _udpFlows[key];
		if (now - flow.lastActivity > VLNetUDPFlowIdleTimeout) {
			[self closeUDPFlow:flow];
		}
	}
}

#pragma mark - 发帧

- (void)sendEthernetToGuest:(const uint8_t *)payload
					 length:(NSUInteger)length
				  etherType:(uint16_t)etherType {
	NSMutableData *frame = [NSMutableData dataWithCapacity:VLNetEthernetHeaderLength + length];
	uint8_t header[VLNetEthernetHeaderLength];
	memcpy(header, VLNetGuestMAC, 6);
	memcpy(header + 6, _macAddress.bytes, 6);
	VLWriteBE16(header + 12, etherType);
	[frame appendBytes:header length:sizeof(header)];
	[frame appendBytes:payload length:length];
	[self enqueueFrame:frame];
}

- (void)sendIPv4From:(uint32_t)source
				  to:(uint32_t)destination
		  protocol:(uint8_t)protocol
		   payload:(NSData *)payload {
	NSUInteger totalLength = VLNetIPv4HeaderLength + payload.length;
	if (totalLength > 65535) {
		return;
	}
	uint8_t header[VLNetIPv4HeaderLength] = { 0 };
	header[0] = 0x45;
	VLWriteBE16(header + 2, (uint16_t)totalLength);
	header[8] = 64;
	header[9] = protocol;
	VLWriteBE32(header + 12, source);
	VLWriteBE32(header + 16, destination);
	VLWriteBE16(header + 10, VLChecksum(header, sizeof(header)));

	NSMutableData *packet = [NSMutableData dataWithCapacity:totalLength];
	[packet appendBytes:header length:sizeof(header)];
	[packet appendData:payload];
	[self sendEthernetToGuest:packet.bytes length:packet.length etherType:0x0800];
}

- (void)sendUDPFrom:(uint32_t)source
				 to:(uint32_t)destination
		 sourcePort:(uint16_t)sourcePort
	destinationPort:(uint16_t)destinationPort
			payload:(NSData *)payload {
	uint8_t header[VLNetUDPHeaderLength] = { 0 };
	VLWriteBE16(header, sourcePort);
	VLWriteBE16(header + 2, destinationPort);
	VLWriteBE16(header + 4, (uint16_t)(VLNetUDPHeaderLength + payload.length));

	NSMutableData *segment =
		[NSMutableData dataWithCapacity:VLNetUDPHeaderLength + payload.length];
	[segment appendBytes:header length:sizeof(header)];
	[segment appendData:payload];
	[self sendIPv4From:source to:destination protocol:17 payload:segment];
}

- (void)sendTCPFrom:(uint32_t)source
				 to:(uint32_t)destination
		 sourcePort:(uint16_t)sourcePort
	destinationPort:(uint16_t)destinationPort
		   sequence:(uint32_t)sequence
	acknowledgement:(uint32_t)acknowledgement
			  flags:(uint8_t)flags
			payload:(NSData *)payload {
	uint8_t header[VLNetTCPHeaderLength] = { 0 };
	VLWriteBE16(header, sourcePort);
	VLWriteBE16(header + 2, destinationPort);
	VLWriteBE32(header + 4, sequence);
	VLWriteBE32(header + 8, acknowledgement);
	header[12] = 5 << 4;
	header[13] = flags;
	VLWriteBE16(header + 14, VLNetReceiveWindow);

	NSMutableData *segment =
		[NSMutableData dataWithCapacity:VLNetTCPHeaderLength + payload.length];
	[segment appendBytes:header length:sizeof(header)];
	[segment appendData:payload ?: [NSData data]];
	uint8_t *segmentBytes = segment.mutableBytes;
	VLWriteBE16(segmentBytes + 16,
				VLTransportChecksum(source, destination, 6, segment.bytes, segment.length));
	[self sendIPv4From:source to:destination protocol:6 payload:segment];
}

@end
