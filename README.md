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

## 当前状态

- 已完成：Theos 工程、UIKit 界面、rootless deb 打包、GitHub Actions 自动编译（每次推送产出 deb artifact）。
- 待接入：虚拟化后端。`src/VLLinuxVirtualMachine.m` 目前只做能力校验，点「启动」会明确报出缺什么；界面会实时显示设备型号、系统版本、越狱环境、Hypervisor 是否存在。
- 不入库：从 macOS 抽取的 Apple 私有二进制（Hypervisor / Virtualization / ParavirtualizedGraphics）。版权原因不进公开仓库，需要本地生成后放进 `VirtualLinux.app/Frameworks/`。

## 构建

本地具备 Theos 时：

```sh
make package FINALPACKAGE=1
```

产物在 `packages/`。

## CI

`.github/workflows/build-rootless-deb.yml`：

1. 检出源码，装 `ldid` 与 `dpkg`
2. 克隆 Theos 并配置 `$THEOS`
3. 校验 `control` 架构、系统上限、`Info.plist` 最低版本
4. `make package FINALPACKAGE=1` 打包 rootless deb
5. 用 `dpkg-deb` 校验架构为 `iphoneos-arm64`、App 落在 `/var/jb/Applications/VirtualLinux.app`
6. 上传 `VirtualLinux-DEB` artifact（保留 30 天）

失败时会额外上传 `build-log`。

## 安装

1. 用 Dopamine 越狱（系统必须是 14.0 – 16.3.1）
2. 下载 CI 的 `VirtualLinux-DEB` artifact
3. Sileo / Filza 安装 deb，`postinst` 会执行 `uicache` 让图标出现

## 下一步

1. 从 macOS 抽取 Hypervisor 栈，`ldid` 重签后放入 `Frameworks/`
2. 接 hv 内存映射与 vCPU 循环
3. virtio-blk / virtio-net / virtio-input，接上 framebuffer 显示
4. 内置或导入 Linux 内核与根文件系统
