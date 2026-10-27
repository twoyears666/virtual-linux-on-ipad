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

- 已完成：Theos 工程、双栏界面、rootless deb 打包、分支 IPA 打包、GitHub Actions 自动编译、多存储位置与冻结、设置页与日志导出、ISO 安装盘解析（抽内核/initrd、Debian 系 preseed）。
- 已完成（虚拟化后端）：运行时从 `Frameworks/` 加载 Hypervisor.framework；客户机内存映射；自己拼 FDT（内存 / PSCI / armv8 定时器 / GICv2 / PL011 / virtio-mmio）；设备总线与 MMIO 异常模拟；GICv2 子集（SPI + 虚拟定时器 PPI）；PL011 串口输出接到 App 日志；virtio-gpu 2D 扫描输出，客户机 flush 时把像素取回显示；virtio-blk 挂载系统盘镜像；virtio-input 单点触摸屏，详情页里的手指位置直接送进客户机。
- 尚未接入：virtio-net（网络）。
- 不入库：从 macOS 抽取的 Apple 私有二进制（Hypervisor / Virtualization / ParavirtualizedGraphics）。版权原因不进公开仓库，需要本地生成后放进 `VirtualLinux.app/Frameworks/`。

## 构建

本地具备 Theos 时：

```sh
make package FINALPACKAGE=1   # 出 rootless deb
```

Hypervisor.framework 要自己从 macOS 抽取（Apple 没给 iPadOS 的 SDK），在 arm64 Mac 上：

```sh
# 1. 拷出二进制（同一版本号内的 macOS 与 iPadOS 15/16 内核 ABI 一致）
mkdir -p VirtualLinux.app/Frameworks/Hypervisor.framework
cp /System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor \
   VirtualLinux.app/Frameworks/Hypervisor.framework/Hypervisor

# 2. 让 App 能找到它，并补一个最小 Info.plist
plutil -create xml1 VirtualLinux.app/Frameworks/Hypervisor.framework/Info.plist
plutil -insert CFBundleIdentifier -string com.apple.Hypervisor \
       VirtualLinux.app/Frameworks/Hypervisor.framework/Info.plist
plutil -insert CFBundleExecutable -string Hypervisor \
       VirtualLinux.app/Frameworks/Hypervisor.framework/Info.plist

# 3. 重签成设备可加载的形态（rootless 越狱用 ldid 即可）
ldid -S VirtualLinux.app/Frameworks/Hypervisor.framework/Hypervisor
```

App 启动时按 `Frameworks/Hypervisor.framework/Hypervisor` 的顺序查找，找不到就在状态里报「Hypervisor 不可用」，不会直接闪退。

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

1. 从 macOS 抽取 Hypervisor 栈，`ldid` 重签后放入 `Frameworks/`
2. virtio-net，把网络接上
3. 内置或导入可启动的内核与根文件系统（virtio-blk 已能挂载镜像）
4. 真机验证 GIC 中断注入、EL1 虚拟定时器与 virtio 队列收发
