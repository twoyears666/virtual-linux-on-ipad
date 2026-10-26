#import <Foundation/Foundation.h>

/// ISO 自动安装的解析结果。
@interface VLISOInstallResult : NSObject

/// debian / ubuntu / unknown，按 ISO 目录结构判断。
@property (nonatomic, copy) NSString *family;
/// 抽出来的内核路径（虚拟机目录内）。
@property (nonatomic, copy) NSString *kernelPath;
/// 抽出来的 initrd 路径。
@property (nonatomic, copy) NSString *initrdPath;
/// 生成的自动应答文件路径；非 Debian 系为空。
@property (nonatomic, copy) NSString *preseedPath;
/// 给人看的说明，例如「Debian 系安装盘 · 已抽取内核与 initrd」。
@property (nonatomic, copy) NSString *summary;

@end

/// 解析 Linux 安装 ISO（ISO9660）：找 Debian 系的 install 目录，
/// 抽出内核与 initrd，并按 virtio 磁盘（/dev/vda）生成 preseed.cfg。
/// 目前只覆盖 Debian 系；其它发行版只做识别，不做自动应答。
@interface VLISOInstaller : NSObject

/// machineDirectory 是这台虚拟机的根目录，产物写到它的 boot/ 与 autoinstall/ 下。
/// 失败返回 nil，error 说明原因（例如不是 ISO9660、找不到 install 目录）。
+ (VLISOInstallResult *)prepareISOAtPath:(NSString *)isoPath
						machineDirectory:(NSURL *)machineDirectory
					   distroIdentifier:(NSString *)distroIdentifier
								  error:(NSError **)error;

@end
