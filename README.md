# Virtual Linux on iPad

在越狱的 iPadOS / iOS 14.0 – 16.3.1 上用硬件虚拟化跑 Linux 虚拟机。

思路参考 [VirtualMacOniPad](https://github.com/nfzerox/VirtualMacOniPad)：iPadOS 14 – 16.3.1 的 XNU 内核仍保留 Hypervisor 支持，Apple 在 16.4 里把它移除了。所以只要把 macOS 的 Hypervisor / Virtualization 栈抽取并重签成 iOS 可加载的形态，就能在设备上直接创建 VM。

和 Virtual Mac 的差别：Linux 客户机只需要内核 + initrd + virtio 设备，不需要 macOS 那套 DFU / restore 安装链路，工程量小得多。

## 支持范围

| 项目 | 要求 |
| --- | --- |
| 系统 | iPadOS / iOS 14.0 – 16.3.1（16.4 起无 Hypervisor） |
| 越狱 | Dopamine 等 rootless 越狱，包安装在 `/var/jb` |
| 包架构 | `iphoneos-arm64` |
| 设备 | 支持 Hypervisor 的设备，例如 M1/M2 iPad、iPhone 14 Pro |

## 存放位置

- 默认位置是 `/var/mobile/Media/VirtualMachines`（越狱后 App 不受沙盒限制，卸载重装、换签名、刷机都不会把手里的虚拟机带走）；目录建不出来时退回 App 文档目录下的 `VirtualMachines`
- 设置页可再登记任意文件夹（例如外接磁盘），用 security-scoped 书签持久化，重启后自动恢复访问
- 多个位置共存，新建虚拟机时可在「存储 → 存放位置」里选；已有虚拟机不迁移
- 位置目录不在了（外接盘拔出、目录被删）时，它下面的虚拟机在列表和详情页标为「已冻结」：不能启动，但配置仍可查看，目录恢复后自动解冻

## 设置页

- 关于：版本号、项目仓库链接、赞助（链接待补）
- 存储位置：查看/添加/移除登记的位置（内置位置不可移除，移除登记不删目录里的文件）
- 日志：一键把系统信息、存储位置清单、统一日志、启动埋点、崩溃记录合并成一个文本分享出去

## ISO 自动安装（进行中）

置备时解析 ISO9660 安装盘：Debian 系（`install.amd` / `install` / `install.386` 目录）抽出内核与 initrd 到虚拟机目录的 `boot/`，并按 virtio 磁盘（`/dev/vda`）生成 `autoinstall/preseed.cfg` 自动应答；Ubuntu（`casper`）只抽内核与 initrd。其它发行版目前只识别不做自动应答。虚拟化后端已经能把内核跑起来，接上 virtio-blk 后即可直接跑无交互安装。

发行版图标来自各发行版官方 logo（经 Wikimedia Commons 转成 512px PNG，见 `Resources/logos/`），仅作发行版识别，商标归各自项目所有。

## 当前状态

- 已完成：Theos 工程、双栏界面、rootless deb 打包、分支 IPA 打包、GitHub Actions 自动编译、多存储位置与冻结、设置页与日志导出、ISO 安装盘解析（抽内核/initrd、Debian 系 preseed）、Hypervisor.framework 抽取与重签脚本。
- 已完成（虚拟化后端）：运行时从 `Frameworks/` 加载 Hypervisor.framework；客户机内存映射；自己拼 FDT（内存 / PSCI / armv8 定时器 / GICv2 / PL011 / virtio-mmio）；设备总线与 MMIO 异常模拟；GICv2 子集（SPI + 虚拟定时器 PPI）；PL011 串口输出接到 App 日志；virtio-gpu 2D 扫描输出，客户机 flush 时把像素取回显示；virtio-blk 挂载系统盘镜像；virtio-input 单点触摸屏，详情页里的手指位置直接送进客户机；virtio-net 出站网络（ARP / DHCP / DNS 转发 / TCP 代理）。
- 尚未接入：端口转发（主机连进客户机）、virtio-net 的 UDP 直连与 IP 分片。
- 不入库：从 macOS 抽取的 Apple 私有二进制（Hypervisor / Virtualization / ParavirtualizedGraphics）。版权原因不进公开仓库，需要本地用 `tools/extract-hypervisor.py` 生成后自动打进 App 的 `Frameworks/`。

## 构建

本地具备 Theos 时：

```sh
make package FINALPACKAGE=1   # 出 rootless deb
```

Hypervisor.framework 要自己从 macOS 抽取（Apple 没给 iPadOS 的 SDK）。macOS 15 起二进制不再以文件形式落在磁盘上，只在 dyld 共享缓存里，所以用脚本抽：

```sh
brew install blacktop/tap/ipsw ldid
python3 tools/extract-hypervisor.py
```

脚本做三件事：从本机 dyld 共享缓存抽 `Hypervisor.framework`；把 Mach-O 的平台从 macOS 改成 iOS、最低版本改成 14.0（否则设备上的 dyld 不认）；`ldid -S` 重签。产物落在 `build-private/Frameworks/Hypervisor.framework`，该目录不入库，`make package` 时若存在就自动拷进 App 的 `Frameworks/`；CI 上没有这个目录，产物里不含 Apple 私有二进制。

App 启动时按 `Frameworks/Hypervisor.framework/Hypervisor` → `/var/jb/usr/lib/libHypervisor.dylib` → 系统路径的顺序查找，找不到就在状态里报「Hypervisor 不可用」，不会直接闪退。

## 支持安装的发行版

硬条件：客户机内核必须是 arm64（aarch64）的 `Image`，并且带 virtio-blk / virtio-gpu / PL011 串口驱动；x86 的 bzImage、只走 EFI 引导的镜像都拉不起来。

| 发行版 | ISO 解析 | 目前能到哪一步 |
| --- | --- | --- |
| Debian 11 / 12 / 13（arm64 安装盘） | 识别 `install` 目录，抽出内核与 initrd，按 `/dev/vda` 生成 preseed 自动应答 | 可引导进安装器，DHCP / DNS / HTTP 已能通；安装要配合 preseed 自动应答，交互式安装还缺键盘 |
| Ubuntu 22.04 / 24.04（arm64，casper） | 识别 `casper`，抽出内核与 initrd | 只做抽取，没有自动应答 |
| Alpine / Fedora / Arch 等 | 只按 `boot` / `isolinux` 目录兜底找 `vmlinuz` + `initrd` | 需要自己备好 arm64 内核与 initrd |

网络说明：客户机固定 `10.0.2.15/24`，网关 `10.0.2.2` 兼 DHCP 与 ICMP，DNS `10.0.2.3` 转发到 `8.8.8.8`，TCP 出站用真实 socket 代理；UDP 只转 DNS，其它 UDP 和 IP 分片暂不支持。

结论：还没有哪个发行版能一键装完。现在能用的是「自带 arm64 内核 + initrd，配一块 virtio 磁盘镜像」这条路径；交互式安装还需要串口键盘或更完整的自动应答。

## CI

分支和产物的对应关系见 [rules.md](rules.md)，摘要：

| 分支 | 产物 |
| --- | --- |
| `main` | `VirtualLinux-DEB`（rootless deb） |
| `dev` / `feat/**` / `fix/**` | `VirtualLinux-IPA`（未签名，供 TrollStore / AltStore 重签） |

两个 workflow 都会校验产物结构：deb 查 `iphoneos-arm64` 与 `/var/jb/Applications/VirtualLinux.app`，IPA 查 `Payload/VirtualLinux.app` 与 `MinimumOSVersion`。

## 安装

- deb：Dopamine 越狱后，用 Sileo / Zebra / Filza 安装。`postinst` 先 `uicache -p` 刷新图标缓存，再往安装器的 `$CYDIA` 结果描述符写 `finish:restart`，所以装完会提示「重启 SpringBoard」——同意重启后主屏才会出现图标（用 Filza 直接 `dpkg -i` 装的话，装完手动 respring 一次即可）。
- IPA：界面测试包，不带任何越狱权限（`entitlements-ipa.plist` 是空字典）。TrollStore 直接装，或 AltStore / Sideloadly 用自己的证书重签；不越狱也能装来看界面。
- 注意：IPA 只能看界面，真正启动虚拟机仍然必须越狱（要加载私有 Hypervisor 运行时）。

## 闪退排查

`UIFileSharingEnabled` 已打开，App 沙盒的 `Documents` 里会留三份日志：

| 文件 | 内容 |
| --- | --- |
| `logs/app.log` | 统一日志，所有运行期信息逐行带时间戳，超过 512 KB 轮转到 `app.1.log` |
| `startup.log` | 启动阶段埋点，逐行带时间戳（窗口创建、根控制器、分栏装载、各设置卡片、首次布局） |
| `crash.txt` | 未捕获异常的名称/原因/调用栈，以及 SIGABRT / SIGSEGV 等致命信号 |

最省事的是设置页「导出日志」：把系统信息、存储位置清单和上面三份日志合并成一个文本，直接分享出去。

取日志方式：

- 未越狱：文件 App → 我的 iPad → Virtual Linux → `logs/app.log` / `startup.log` / `crash.txt`
- 越狱：Filza 进 App 沙盒 `Documents`，或 Mac 上用 Finder 文件共享
- 连电脑：Xcode → Devices and Simulators → 选中 App → 下载容器

`app.log` / `startup.log` 最后一行就是崩溃前完成的最后一步，配合 `crash.txt` 的调用栈即可定位。

## 下一步

1. 串口键盘（把客户机的 /dev/ttyAMA0 接上输入），交互式安装才有可能
2. 端口转发与 UDP 直连，让主机能连进客户机
3. 内置或导入可启动的根文件系统（virtio-blk 已能挂载镜像）
4. 真机验证 GIC 中断注入、EL1 虚拟定时器与 virtio 队列收发
