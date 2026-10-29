#import <Foundation/Foundation.h>

/// 探测运行环境是否具备硬件虚拟化条件。
/// iPadOS 14.0 – 16.3.1 的 XNU 内核仍保留 Hypervisor 支持，16.4 起被移除。
@interface VLHostCapabilities : NSObject

/// 形如 16.3.1 的系统版本字符串。
+ (NSString *)systemVersionString;

/// 系统是否落在 14.0 – 16.3.1 区间内。
+ (BOOL)isSystemVersionSupported;

/// 是否能找到可用的 Hypervisor 运行时（hv_vm_create 符号）。
+ (BOOL)isHypervisorUsable;

/// 已加载的 Hypervisor 二进制路径；没有加载成功时返回 nil。
+ (NSString *)hypervisorSource;

/// 给人看的诊断信息，用于界面展示。
+ (NSString *)diagnosticReport;

/// 本机物理内存（MB）。
+ (NSUInteger)physicalMemoryMB;

/// 本进程还能拿到的内存（MB），iOS 13 起可用；拿不到时退回本机剩余物理内存的估算值。
+ (NSUInteger)availableMemoryMB;

/// 本进程当前驻留内存（MB），用来确认客户机内存到底是真占住了还是按需分配的。
+ (NSUInteger)residentMemoryMB;

/// 客机内存上限：本机内存的一半，且至少给系统留 2 GB，按 512 MB 取整。
/// 留得不够，前台就会把系统服务（例如媒体服务）挤到被 jetsam 杀掉——
/// 表现是全机没声音，只有强退占用内存的 App 才恢复。
+ (NSUInteger)maximumGuestMemoryMB;

@end
