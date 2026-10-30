# 计划：Virtualization.framework 作为第二后端

状态：待启动（大活）。本文只定方案与验收门，不含实现。

## 1. 目标与非目标

目标：

- 在现有 App 里增加一个 **VZ 后端**：把 macOS 的 `Virtualization.framework` 从 dyld 共享缓存抽出来、restamp 到 iPadOS，用它引导 Linux 客户机。
- 两个后端对上层**完全等价**：同一套 UI、同一份 VM 配置、**同一块磁盘镜像**，启动前选后端即可。
- 后端不可用时自动回落到自研后端，用户不受影响。

非目标：

- 不做运行中热迁移（两边设备树、vCPU 状态、内存布局都不同，做不到）。
- 不用 VZ 引导 macOS（那是 VirtualMacOniPad 的目标，不是我们的）。
- 不改客户机侧：客户机始终是「arm64 virt + virtio」的标准 Linux。

## 2. 为什么值得做

自研栈踩过的坑，VZ 全都自带正确实现：

| 问题 | 自研栈现状 | VZ 后端 |
|---|---|---|
| GIC | 模拟 GICv2 + 踢核注入 pending | 硬件 vGIC（GICv3） |
| 串口 | 模拟 PL011，每字符一次 MMIO 退出 | virtio-console，队列批量 |
| 磁盘/网卡/输入 | 自写 virtio-mmio | Apple 的 virtio 1.0 modern 实现 |
| PSCI / SMCCC | 自己实现（踩过 64 位功能号、ELR 语义） | 框架实现 |
| 启动链 | 自拼 FDT + 直跳内核 | 直跳内核 or UEFI |

代价：黑盒。出问题不能再「读日志对内核源码」。所以 VZ 后端**只作为第二选项**，自研栈保留为默认与兜底。

## 3. 架构

现状：`VLLinuxVirtualMachine` 既是编排者又是 HVF 后端，UI 直接依赖它。

改为三层：

```
UI（VLDetailViewController / VLFullScreenViewController / VLKeyboardInput）
   ↓ 只依赖协议
VLMachineBackend（协议）        ← 状态、状态文字、显示尺寸、串口行、触摸、启停、delegate
   ├── VLHypervisorMachine       ← 现有 VLLinuxVirtualMachine，改名并收敛为后端
   └── VZMachineBackend          ← 新增：VZ 后端
```

`VLMachineBackend` 需覆盖的成员（与现有 UI 调用一一对应）：

- 生命周期：`startWithError:` / `stop` / `state` / `statusMessage`
- 输出：`delegate`（显示帧、串口行、状态变化）、`displayWidth` / `displayHeight`
- 输入：`sendTouchBeganAtNormalizedX:y:` / `sendTouchMovedToNormalizedX:y:` / `sendTouchEnded`
- 画面尺寸变更回调（VZ 的 scanout 尺寸来自配置，需同样上报）

VM 配置增加一个字段 `backend`（`auto` / `native` / `vz`），默认 `auto`：先试 VZ，不可用或启动失败即回落 native，并在日志里写明原因。

## 4. 阶段与验收门

每个阶段末尾都有「不过就不往下走」的验收门。

### 阶段 0：可行性探针（最先做，单独可交付）

- `dlsym` 探测：`hv_gic_*`（vGIC）、`Virtualization.framework` 是否可加载（`dlopen` 私有路径 + 符号存在性）。
- 结果写进 `startup.log`，并在 App 内可见（详情页「诊断」一节即可）。
- **验收门**：拿到设备上确切的「有 / 无」结论。没有 vGIC 也不影响 VZ 后端（VZ 自带），但决定自研栈是否也能吃上 vGIC。

### 阶段 1：构建期抽取管线

- 用一次性的 macOS 侧脚本（`tools/` 下）从 dyld 共享缓存抽取 `Hypervisor`、`Virtualization`、`ParavirtualizedGraphics`，重定位并 restamp 为 iOS 平台标识。
- 参考 `nfzerox/VirtualMacOniPad`（**MIT**，允许参考与改写，需在文件头署名原作者与出处）。
- **验收门**：抽取产物能在模拟器外、真机上 `dlopen` 成功，`objc_getClass("VZVirtualMachine")` 非空。

### 阶段 2：协议抽象重构（纯重构，不改行为）

- 定义 `VLMachineBackend`，把 `VLLinuxVirtualMachine` 收敛成 `VLHypervisorMachine` 并实现协议；UI 全面改为依赖协议。
- **验收门**：功能零回归 —— 启动、画面、串口日志、键盘、触摸、退出全部与重构前一致（以真机日志比对）。

### 阶段 3：VZ 后端最小可引导

- 配置：`VZVirtualMachineConfiguration` + `VZGenericPlatformConfiguration` + `VZLinuxBootLoader`（kernel + initrd + cmdline）。
- 设备：`VZVirtioBlockDeviceConfiguration`（同一块 raw 镜像）、`VZVirtioNetworkDeviceConfiguration`、`VZVirtioConsoleDeviceSerialPortConfiguration`（挂到串口行输出）。
- 显示：先把 `VZ` 的 scanout 落到 **IOSurface → Metal → 我们的 `VLDisplayView`**（`VZVirtualMachineView` 是 AppKit 的，用不了）。
- 输入：`VZUSBKeyboardConfiguration` / `VZUSBScreenCoordinatePointingDeviceConfiguration`（或 virtio-input），接现有 `VLKeyboardInput` 与触摸归一化坐标。
- **验收门**：串口能出内核日志、能过 `alternatives`、能进 Debian 安装器，且 6 核全起。

### 阶段 4：切换与回落

- 配置字段 `backend` 生效；启动前按 `auto` 顺序尝试，失败即回落并记录原因。
- 同一块镜像在两种后端之间互换启动，**不重装、不改配置**。
- **验收门**：同一镜像 native → vz → native 往返各一次，客户机都能正常启动到同一状态（rootfs 无损、`/dev/vda` 一致）。

### 阶段 5：收敛与默认值

- 根据实测决定 `auto` 的优先顺序（谁快、谁稳谁优先），并写进 README 与详情页说明。
- **验收门**：连续 5 次冷启动无失败；最低配（4 GB 内存）设备也能跑。

## 5. 「无缝切换」到底能做到什么程度

结论：**同一镜像可以无缝互换，但只能在停机状态下切**。

能无缝的前提（设计上必须满足，否则会变成「必须重装」）：

1. 两个后端都把磁盘暴露成 **virtio-blk**，客户机看到的还是 `/dev/vda`，分区与 UUID 不变。
2. 两个后端都走 **直跳内核**（`VZLinuxBootLoader` 支持 kernel + initrd + cmdline），不上 UEFI。这样镜像里不需要写死任何引导器路径。
3. 客户机内核同时支持 **GICv2 与 GICv3**（Debian/Ubuntu 通用 arm64 内核都支持）。VZ 后端给 GICv3，自研后端给 GICv2，同一内核两处都能起。
4. **cmdline 由后端生成**，不写进镜像：串口设备名（`ttyAMA0` vs `hvc0`）、`console=` 顺序、`earlycon=` 都不同。
5. rootfs 里不写死控制台（Debian 默认 `console=ttyAMA0` 的 `/etc/inittab` 之类要避免，或统一用 `console=hvc0` + 回退）。

做不到的：

- 运行中切换（热迁移）：vCPU 状态、设备树、内存映射全不同，物理上不可能。
- 未来若给自研栈加 UEFI（EDK2），两边引导方式就会分叉，那时要么统一到 UEFI，要么镜像分两套。

用户感知：在详情页点「切换后端」→ 虚拟机自动停机并重建 → 重新启动 → 画面与串口照常。**不需要重装系统，不需要改镜像**。

## 6. 风险与回滚

| 风险 | 应对 |
|---|---|
| 抽取产物在某 iPadOS 小版本上失效 | 阶段 0 的探针先给出结论；失败即 `auto` 回落 native |
| VZ 无法引导 Linux（只对 macOS 成立） | 阶段 3 就是为此设的门：起不来即终止整个计划，自研栈不受影响 |
| 显示桥接（IOSurface → Metal）做不通 | 先只做串口后端（`VZ` 跑起来但无画面），验证引导；画面延后 |
| 私有框架稳定性 | 所有 VZ 代码隔离在 `VZMachineBackend` 内，删除即回滚 |
| 许可 | 上游 MIT，参考/改写需保留版权声明与出处 |

## 7. 与自研栈的关系

- 自研栈继续做主线：多核 IPI、串口、virtio-blk 读盘、安装器 —— 这些是默认路径，必须能独立跑通。
- VZ 后端是**并行实验**，不阻塞主线。
- 若阶段 0 探明 `hv_gic_*` 可用，自研栈也应单独切换 vGIC（与 VZ 无关的另一条收益）。
