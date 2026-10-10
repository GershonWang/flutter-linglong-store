# 玲珑容器形态的宿主透传桥设计

## 1. 概述

商店打包为玲珑（UAB）后运行在玲珑容器里。容器内**没有 ll-cli**——玲珑 base 镜像
不含玲珑工具链，且 ll-cli 依赖 Qt6 等宿主库，打进包要连带一堆依赖。而商店的全部
应用管理能力（已装列表、安装、卸载、更新、运行）都建立在 ll-cli 之上。

本设计引入一条**容器内发起、宿主上执行**的命令透传通道，让既有代码在玲珑形态下
继续可用；DEB / RPM / AppImage 与开发态行为完全不变。

- 通道实现：`lib/core/platform/host_escape_channel.dart`
- 命令形态：`BridgedLinglongCliCommandBuilder`（`lib/core/platform/linglong_cli_command.dart`）
- 接入点：组合根 `lib/bootstrap/production_dependency_overrides.dart`

## 2. 为什么必须回宿主执行

实测（Deepin 25 / 玲珑 1.14.3）：

| 做法 | 结果 |
|------|------|
| 容器内直接执行 `/run/host/rootfs/usr/bin/ll-cli --version` | 能打印版本 |
| 容器内直接执行 `…/ll-cli list` | **静默失败**——它依赖宿主命名空间内的守护进程、层仓库与可写状态 |
| 经 `systemd-run --user` 送回宿主执行 | `list`/`install`/`uninstall` 全部正常，退出码与输出原样带回 |

因此通道不是"执行宿主二进制"，而是"请求宿主执行命令"。

## 3. 通道原理

容器与宿主共享用户会话总线（`/run/user/1000/bus`）。`systemd-run --user` 经该总线
请求宿主上的用户 systemd 管理器创建瞬态 unit，进程因此落在容器之外；`--wait --pipe`
把退出码与 stdout/stderr 原样带回。

生成的命令形态固定为：

```
systemd-run --user --quiet --collect --wait --pipe --expand-environment=no \
  --setenv=LC_ALL=C.UTF-8 --setenv=LANG=C.UTF-8 --setenv=LANGUAGE=C.UTF-8 --setenv=LC_MESSAGES=C.UTF-8 \
  --working-directory=<家目录> \
  /bin/sh -c 'exec "$0" "$@"' <宿主命令> <参数…>
```

用 `$0` 承载宿主命令路径、`$@` 承载参数，避免在 shell 里拼引号。

## 4. 三条硬约束（实测踩出来的，改动前必须复验）

| # | 约束 | 不遵守的后果 |
|---|------|-------------|
| 1 | 必须 `--expand-environment=no` | systemd 会展开命令串里的 `$` 形式（实测 `$$` 被改写成 `$`），参数被静默改坏 |
| 2 | 必须用 `--setenv` 显式声明英文 locale | **`systemd-run` 不转发调用者环境变量**（实测 `LC_ALL`/自定义变量在宿主侧均为空）；缺失会让 ll-cli 按宿主语言输出，直接破坏 JSON 与文本表格解析 |
| 3 | `--working-directory` 只能用两侧同路径的目录（家目录） | 指向宿主不存在的路径时**静默失败**：退出码 200、stdout/stderr 全空。玲珑应用的 cwd 常是 `/opt/apps/<appid>/…` 这类容器专有路径，照抄必然踩中 |

另有一条：写进命令的宿主可执行文件路径**不能带宿主根挂载点前缀**——命令在宿主上
执行，宿主没有 `/run/host/rootfs`。

## 5. 探测与降级

`HostEscapeChannel.detect()` 的判据缺一不可：

1. 宿主根只读挂载点存在（只有玲珑容器会挂载它）；
2. `systemd-run` 在 PATH 上可解析；
3. 用户会话总线可用（`DBUS_SESSION_BUS_ADDRESS` 或 `XDG_RUNTIME_DIR`）。

任一不满足即返回 null，组合根**保持本地直调**。宿主上找不到 ll-cli 时同样保持
本地直调——既有的"ll-cli 未安装或不可用"诊断路径会给出可读错误，比在这里静默降级
更好定位。

## 6. 命令形态的单一入口

ll-cli 的调用点跨 Repository / Service / Provider 三层，收敛前有 5 处独立拼接
（其中 `runApp` 自行 `Process.start('ll-cli', …)` 是透传改造的漏网点）。现在统一由
进程级持有者 `linglongCliCommandBuilder` 决定命令形态，调用点只写 ll-cli 参数。

选进程级持有者而不是逐层注入的理由：命令形态是**进程级事实**——商店是单进程桌面
应用，运行形态在进程生命周期内不会变化；逐层注入会把同一个构造器穿过十余个构造器，
且"读哪里"出现多个答案，正是漏点的成因。

## 7. 安全边界（必须评审）

**这是一条沙箱逃逸通道。** 能力面完全由调用方给出的 argv 决定，通道本身不限制子命令。

- 本设计**只接 ll-cli**，不接 pkexec 等提权命令；容器形态下的特权能力按下述方式降级，
  而不是想办法打通：
  - 免密安装（polkit 规则网关）：容器形态下点击提示"当前形态不支持"；
  - 特权 helper：既有信任探测已对"非包管理器安装"的 bundle 判为不可信，玲珑形态自然
    不走 helper，无需改动；
  - 取消安装：桥返回的进程句柄是本地 `systemd-run`，拿不到宿主 ll-cli 的 PID，因此
    容器形态下取消无效，UI 禁用取消按钮。
- 通道对**同 UID 进程不设防**（共享 HOME 可写、命令可被同 UID 进程伪造），与
  `docs/51` 的"威胁模型是同 UID 进程"一致。
- 探测与包装是纯函数，可注入测试；生产路径不做任何命令白名单以外的限制。

## 8. 验证

单元测试：`test/unit/core/platform/host_escape_channel_test.dart`
（探测判据、宿主路径解析、命令形态、三条硬约束是否在 argv 中）。

端到端：按桥生成的**逐字命令**调用宿主 ll-cli，实测
`ll-cli --json list` 返回合法 JSON 且退出码 0。

## 9. 未验证

1. 容器形态下经桥的 `install` 是否需要交互授权、宿主 polkit 代理能否完成认证。
2. 桥在真实 UAB 运行时的行为（本次是在 DSH 的玲珑容器内验证的，base 相同）。
3. 取消语义（已决定容器形态禁用，未实现 `systemctl --user kill` 方案）。
