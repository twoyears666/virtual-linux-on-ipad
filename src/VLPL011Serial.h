#import <Foundation/Foundation.h>

#import "VLDevice.h"

/// PL011 串口的最小实现：只做输出（客户机内核日志），输入恒为空。
/// Linux 用 console=ttyAMA0 就能把启动日志写到这里，方便在 App 里直接看到。
@interface VLPL011Serial : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;

/// 每凑满一行回调一次（带上换行符）。
@property (nonatomic, copy) void (^textHandler)(NSString *line);

/// 客户机往数据寄存器写了多少个字符。用来判断内核到底有没有走到串口初始化，
/// 零就说明它死在更早的地方。
@property (nonatomic, readonly) NSUInteger writtenCharacterCount;

@end
