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

## 界面

参考 UTM 的双栏布局，但设置不再走弹窗，直接在右侧面板改：

- 左栏：虚拟机列表，按发行版显示图标；点 `+` 弹出新建表单（发行版图标、名称、CPU、内存、系统盘容量、ISO 导入）
- 新建表单点「完成」后进入置备阶段：拷贝 ISO、按容量创建稀疏磁盘镜像，全部做完才退出弹窗回到主界面；失败会留在弹窗内提示
- 右栏：截图占位（虚线框，点按即启动，运行后换成客户机画面）+ 内联设置
- 设置分组：基本信息、系统、硬件、存储、显示、网络、输入、运行环境
- 存储支持多块磁盘：第一块是系统盘，可随时「添加磁盘」，新盘可单独调容量或移除
- 磁盘容量在镜像首次创建前可自由调整；镜像创建后再改容量等于新建镜像，原数据不保留（扩容需客户机内配合分区与文件系统，尚未实现）

截图位目前是虚线占位框，等有真实画面再替换。

## 当前状态

- 已完成：Theos 工程、双栏界面、rootless deb 打包、分支 IPA 打包、GitHub Actions 自动编译。
- 待接入：虚拟化后端。`src/VLLinuxVirtualMachine.m` 目前只做能力校验，点「启动」会明确报出缺什么；「运行环境」卡片会显示设备型号、系统版本、越狱环境、Hypervisor 是否存在。
- 不入库：从 macOS 抽取的 Apple 私有二进制（Hypervisor / Virtualization / ParavirtualizedGraphics）。版权原因不进公开仓库，需要本地生成后放进 `VirtualLinux.app/Frameworks/`。

## 构建

本地具备 Theos 时：

```sh
make package FINALPACKAGE=1   # 出 rootless deb
```

## CI

分支和产物的对应关系见 [rules.md](rules.md)，摘要：

| 分支 | 产物 |
| --- | --- |
| `main` | `VirtualLinux-DEB`（rootless deb） |
| `dev` / `feat/**` / `fix/**` | `VirtualLinux-IPA`（未签名，供 TrollStore / AltStore 重签） |

两个 workflow 都会校验产物结构：deb 查 `iphoneos-arm64` 与 `/var/jb/Applications/VirtualLinux.app`，IPA 查 `Payload/VirtualLinux.app` 与 `MinimumOSVersion`。

## 安装

- deb：Dopamine 越狱后，用 Sileo / Filza 安装，`postinst` 会执行 `uicache` 让图标出现。
- IPA：界面测试包，不带任何越狱权限（`entitlements-ipa.plist` 是空字典）。TrollStore 直接装，或 AltStore / Sideloadly 用自己的证书重签；不越狱也能装来看界面。
- 注意：IPA 只能看界面，真正启动虚拟机仍然必须越狱（要加载私有 Hypervisor 运行时）。

## 闪退排查

`UIFileSharingEnabled` 已打开，App 沙盒的 `Documents` 里会留两份自证日志：

| 文件 | 内容 |
| --- | --- |
| `startup.log` | 启动阶段埋点，逐行带时间戳（窗口创建、根控制器、分栏装载、各设置卡片、首次布局） |
| `crash.txt` | 未捕获异常的名称/原因/调用栈，以及 SIGABRT / SIGSEGV 等致命信号 |

取日志方式：

- 未越狱：文件 App → 我的 iPad → Virtual Linux → `startup.log` / `crash.txt`
- 越狱：Filza 进 App 沙盒 `Documents`，或 Mac 上用 Finder 文件共享
- 连电脑：Xcode → Devices and Simulators → 选中 App → 下载容器

`startup.log` 最后一行就是崩溃前完成的最后一步，配合 `crash.txt` 的调用栈即可定位。

## 下一步

1. 从 macOS 抽取 Hypervisor 栈，`ldid` 重签后放入 `Frameworks/`
2. 接 hv 内存映射与 vCPU 循环
3. virtio-blk / virtio-net / virtio-input，接上 framebuffer 显示
4. 内置或导入 Linux 内核与根文件系统
