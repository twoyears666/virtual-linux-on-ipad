# 计划：自研栈更半虚拟化

状态：待启动。
前提：主包（自研栈）先自己跑通到 Debian 安装器；本计划的项可以穿插做，但每项都必须独立可回滚。

## 0. 判断口径

「更半虚拟化」= 减少**陷入次数**和**模拟代码面积**。衡量只有两个指标：

1. `退出次数 / 30 秒`（`startup.log` 里的运行采样）——越低越好；
2. 从开机到 `Run /init` 的耗时（日志时间戳差）。

凡是不能改善这两个指标、也不减少模拟代码的改动，一律不做。

## 1. 优先级总表

| 序 | 项 | 收益 | 风险 | 依赖 |
|---|---|---|---|---|
| P0 | **vGIC（`hv_gic_*`）替换模拟 GICv2** | 删掉整套 GIC 模拟与「踢核 + 手动注入」；多核 IPI 原生延迟 | API 在 iPadOS 上可能不存在/私有 | 阶段 0 探针 |
| P1 | **virtio-console 替代模拟 PL011** | 串口从「每字符一次 MMIO 退出」变成队列批量 | 需要 earlycon 与 hvc0 并存 | 无 |
| P2 | **virtio-mmio 确认走 modern（VERSION_1）** | 队列通知与状态机标准，兼容性与性能都好 | 需确认现实现是 legacy | 无 |
| P3 | 客户机 `loglevel=3` + `quiet` | 启动期串口输出骤降，退出次数直接下降 | 调试期不宜开 | P1 之后 |
| P4 | PV panic 设备 | panic 立刻上报宿主，不用等超时 | 极小 | 无 |
| P5 | virtio-gpu 资源刷新批量化 | 减少画面相关的 MMIO 退出 | 需读现实现 | 无 |
| — | 共享目录（9p / virtiofs） | 功能，不改善指标 | 工程量大 | 放最后，非必须 |

不做：PV 时钟（arm64 有 `CNTVOFF` 架构定时器，够用）、steal time（单 App 独占场景无意义）。

## 2. 阶段与验收门

### 阶段 0：能力探针（先做，几十行）

- `dlopen`/`dlsym` 探：`hv_gic_create` / `hv_gic_config` / `hv_gic_set_spi` / `hv_gic_get_state` 等一串 `hv_gic_*`；顺带探 `hv_vcpu_set_vtimer_mask` 等相邻能力。
- 结论写进 `startup.log`（一行「vGIC 可用 / 不可用」，附失败原因 `dlerror`）。
- **验收门**：拿到设备上的确定结论。没有 → P0 直接砍掉，本计划其余项照常。

### 阶段 1：vGIC 双后端（仅当阶段 0 判定可用）

- 运行时二选一：vGIC 可用 → 生成 `arm,gic-v3` 设备树（分发器 + 每个核的 redistributor 段 + `#redistributor-regions`），中断由 `hv_gic_*` 注入；不可用 → 完全沿用现有模拟 GICv2。
- **关键约束**：设备树与中断注入路径必须由同一处「中断后端」开关决定，不允许出现「DT 写 GICv3、注入走模拟」这种混搭。
- **验收门**：6 核全起、过 `stop_machine`/`alternatives`、IPI 正常；运行采样里 `退出次数/30 秒` 相比 GICv2 后端明显下降。

### 阶段 2：virtio-console

- 新增 `virtio-console` 设备（virtio-mmio，SPI 号顺延），客户机侧走 `hvc0`；PL011 保留仅供 `earlycon`。
- 客户机 cmdline：`earlycon=pl011,0x9000000 console=hvc0`（顺序不能反）。
- **验收门**：日志出现 `console [hvc0] enabled`，内核日志完整不断行（不能丢字）；启动期退出次数下降。

### 阶段 3：virtio-mmio modern

- 读现实现，确认 `Version` 寄存器与 `VIRTIO_F_VERSION_1` 协商；若为 legacy 则切 modern（1.0 队列、`QueueNotify`、`Status` 状态机、features 高低位）。
- **验收门**：`virtio_blk` 探测日志里版本为 modern，读盘正常，无新增告警。

### 阶段 4：噪音收敛与诊断设备

- `loglevel=3`（默认，安装/调试模式可在设置里放开到 7）；PV panic 设备上线。
- **验收门**：默认启动的退出次数比阶段 2 再降；panic 场景宿主侧有明确一行记录。

## 3. 度量方法（每阶段都要出数）

每次验收都从 `归档.zip` 里取三样：

1. `startup.log` 的 `退出 N 次/30 秒` 采样序列；
2. 首行到 `Run /init` 的时间戳差；
3. 阶段前后同一 cmdline 下的 `MMIO 访问次数`。

三个数任一没变好，就说明这阶段白做，回滚。

## 4. 风险与回滚

| 风险 | 应对 |
|---|---|
| `hv_gic_*` 在 iPadOS 上不可用 | 阶段 0 就砍，零成本 |
| vGIC 起得来但中断投递语义不对（极性/边沿） | 后端开关一键切回模拟 GICv2 |
| virtio-console 丢字（队列未满就覆盖） | 保留 PL011 作为回退控制台，cmdline 可切换 |
| modern virtio 与老镜像不兼容 | 保留 legacy 分支，按设备配置选择 |

## 5. 与外层的边界

本计划全部改动都在主包内（自研栈），不依赖、也不引用任何 Apple 抽取的二进制。
VF（Virtualization.framework）相关的能力走**独立仓库 / 扩展包**，见 `plan-vz-backend.md`，与本文互不阻塞。
