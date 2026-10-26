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

@end
