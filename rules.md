# CI 规则

## 分支与产物

| 触发分支 | workflow | 产物 | 用途 |
| --- | --- | --- | --- |
| `main` | `build-rootless-deb.yml` | `VirtualLinux-DEB`（`iphoneos-arm64` rootless deb） | 真机安装 |
| `dev` / `feat/**` / `fix/**` | `build-ipa.yml` | `VirtualLinux-IPA`（未签名 IPA） | 界面测试 |
| 任意分支手动触发 | 对应 workflow | 同上 | 临时验证 |

硬性约定：

- `main` **只出 deb**，不出 IPA。
- 分支**只出 IPA**，不出 deb。
- IPA 不做开发者签名，靠 TrollStore 或 AltStore / Sideloadly 重签安装。
- 两个 workflow 都支持 `workflow_dispatch` 手动触发。

## 命名

- 文件名 = 具体动作，kebab-case：`build-rootless-deb.yml`、`build-ipa.yml`
- 顶层 `name` 英文 Title Case，体现产物：`Build Rootless DEB`、`Build IPA`
- job id 英文语义化（`build`），`name:` 中文具体（`编译打包`）
- step `name:` 中文、动词开头、写到具体动作，禁止 `Setup` / `Run` 这类空名
- 失败兜底步骤以`（失败时）`结尾，并带 `if: failure()`

## 产物

- artifact 名英文：`VirtualLinux-DEB`、`VirtualLinux-IPA`、`build-log`
- 产物 `if-no-files-found: error` + `retention-days: 30`
- 诊断日志 `if-no-files-found: warn` + `retention-days: 7`

## 签名与权限

- deb（`main`）：用 `entitlements.plist`，带 `platform-application` 等越狱权限，装进 `/var/jb` 由越狱环境放行。
- IPA（分支）：改用 `entitlements-ipa.plist`（空字典），**不带任何私有权限**。带了会被 amfid 在进程启动时直接杀掉，表现就是点图标闪退。
- IPA 只是界面测试包，不越狱也能装（TrollStore 或自签）；真正跑虚拟机仍然必须越狱，因为要加载私有 Hypervisor 运行时。

## 并发与权限

- `concurrency.group: ${{ github.workflow }}-${{ github.ref }}` + `cancel-in-progress: true`
- `permissions: contents: read`，当前没有发布 release 的需求

## 改动后自查

1. 文件是不是动作名、kebab-case
2. 分支和产物有没有越界（main 不许出 IPA，分支不许出 deb）
3. 每个 step 名字是否具体、动词开头
4. artifact 的 `if-no-files-found` 和 `retention-days` 是否写全
5. `concurrency` 与 `permissions` 是否保留
