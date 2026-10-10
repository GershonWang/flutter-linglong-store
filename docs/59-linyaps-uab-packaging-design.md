# 玲珑（linyaps）UAB 打包设计

## 1. 概述

本仓库为如意玲珑（linyaps）提供 UAB 打包支持，与 DEB / RPM / AppImage / AUR 并列
为第四种发行形态。入口：

```
build/scripts/package-linyaps.sh --version 3.7.0 --arch amd64
```

产物为 `build/out/linux/<version>/<arch>/linglong-store_<version>_<arch>.uab`，
由 `ll-builder export --uabx` 导出（UAB 是玲珑的可执行自包含包格式）。

本设计只覆盖**打包链路**。**当前产物运行时功能不完整**，原因与后续方案见第 5 节，
这一点必须先读，避免把「能打包」误当成「能用」。

## 2. 为什么不能沿用现有打包链路

### 2.1 实测约束

| # | 事实 | 实测证据 |
|---|------|---------|
| 1 | 玲珑 base 镜像**没有任何玲珑工具链** | 容器内 `/usr/bin/ll-cli`、`ll-builder`、`ll-pica` 均不存在，dpkg 数据库无 linglong/linyaps 包 |
| 2 | base 镜像**无编译工具链、无 apt** | `gcc/g++/make/cmake/ninja/pkg-config` 全部缺失，`/usr/bin/apt*` 不存在（仅 `dpkg-deb`） |
| 3 | base 镜像**无 pkexec / polkitd** | `/usr/bin/pkexec`、`/usr/lib/polkit-1/polkitd` 不存在，dpkg 无 `policykit-1` |
| 4 | base 镜像**有 GTK3 运行时** | dpkg 内含 `libgtk-3-0`、`libepoxy0`、`libxkbcommon0`；Flutter 产物可在容器内启动 |
| 5 | `ll-builder` 只能在宿主运行 | 它需要宿主的玲珑守护进程、层仓库（宿主 `/var/lib/linglong`）与可写构建状态；容器内直调宿主二进制会静默失败 |
| 6 | 构建容器注入 `PREFIX` 与 `LINGLONG_APPID` | 实测 `PREFIX=/opt/apps/<appid>/files`、`LINGLONG_APPID=<appid>`，`DESTDIR` 未设置 |
| 7 | 构建容器把工作目录挂成 `/project` | 实测 cwd 为 `/project`，即 `ll-builder` 的调用目录 |
| 8 | `ll-builder` 会在工作目录创建 `linglong/` 状态目录 | 实测仓库根目录被留下未跟踪的 `linglong/`，因此构建必须在 `build/tmp/` 下进行 |
| 9 | `ll-builder` 自动改写 desktop 的 `Exec` | 二进制内含 `# replace 'Exec=XX' to 'Exec=ll-cli run ${appId} -- "XX"'`；本机已装应用的 desktop 实测为 `Exec=/usr/bin/ll-cli run <appid> -- /opt/apps/<appid>/files/bin/...` |
| 10 | 只有 `share/` 下的特定目录会导出给宿主 | 宿主 `/usr/share/linglong/export-dirs.json` 列出 `share/applications`、`share/icons`、`share/mime` 等 |

### 2.2 结论

Flutter 产物**不能在玲珑构建容器内编译**（约束 2），但**必须在宿主的 ll-builder
里装配导出**（约束 5）。因此本格式采用与 RPM「二进制重打包」轨道同构的双轨制：

| 阶段 | 执行环境 | 负责者 |
|------|---------|--------|
| 编译 Flutter 产物 | 发布容器（Debian 10 + Flutter SDK） | `build/scripts/build-linux-bundle.sh` |
| 渲染 desktop / 图标 / AppStream | 发布容器 | `build/scripts/render-packaging-templates.sh` |
| 装配 + `ll-builder build` + `export --uabx` | **宿主机** | `build/scripts/package-linyaps.sh` |

因此 `package-linyaps.sh` **刻意不做** `--inner` 重入（与其它 `package-*.sh` 相反）：
它固定在宿主侧编排，并在检测到 `LINGLONG_RELEASE_CONTAINER` 时失败闭合。

## 3. 打包链路

### 3.1 暂存目录

`build/tmp/package-linyaps/<version>-<arch>/`（`build/tmp` 已被 `.gitignore` 忽略，
`ll-builder` 的 `linglong/` 状态目录因此不会污染工作树，见约束 8）：

```
linglong.yaml          # 由 build/packaging/linux/linyaps/linglong.yaml.in 渲染
build.sh               # 装配脚本，由 ll-builder 在容器内执行
payload/               # Flutter bundle 内容（bin + lib/ + data/ + libexec/）
share/                 # 待导出给宿主的 share 树
  applications/<canonical desktop id>
  icons/hicolor/256x256/apps/linglong-store.png
rendered/              # render-packaging-templates.sh 的原始输出（含 compat desktop）
```

`payload/` 与 `share/` 分离，使 `build.sh` 成为**纯复制器**：它不需要知道应用 ID、
desktop 文件名或图标名，只需把两棵树搬到 `$PREFIX` 与 `$PREFIX/share`。

### 3.2 关键实现约定

- **应用身份单一来源**：清单里的 `package.id`、desktop 文件名、容器内数据目录都派生自
  `config/application_identity.conf`，由 `load_application_identity` 读取，禁止在
  `linyaps/` 目录里另写一份 ID。
- **desktop 的 Exec 改写为包内绝对路径**：`ll-builder` 会把 `Exec` 包成
  `ll-cli run <appid> -- <Exec>`（约束 9），容器内没有 PATH 查找，裸命令名会启动失败。
  `%u` 保留以承接 `og://` 安装链接。
- **desktop 模板复用共享渲染器**：自然语言字段由 ARB 生成器渲染，`linyaps/` 目录不新增
  desktop 模板，避免第二份翻译来源。
- **版本号转换只做一次**：仓库发布版本是三段式（`3.7.0`），玲珑要求四段式
  （`3.7.0.0`）。nightly 版本号含 `+<sha>`，不符合玲珑版本号语法，脚本**失败闭合**
  而不是拼出一个装不上的包。
- **必须用默认导出模式**：`ll-builder export` 不带 `--uabx` 产出的是**可安装** UAB
  （`ll-cli install <file.uab>`）；`--uabx` 产出的是「可执行 UABX」，设计为直接运行
  （`./xxx.uab`），`ll-cli install` 会直接拒绝并报
  `Error -1: executable UAB installation is not supported`（实测）。两者都是 ELF
  可执行文件，肉眼与 `file` 命令都无法区分，只能靠导出参数保证。图标随
  `share/icons` 打进层内即可，不需要 `--icon`（该参数仅对 `--uabx` 有效）。
- **暂存目录清理必须先修权限**：`ll-builder` 的 overlay workdir 权限为 `0000`
  （属主仍是当前用户），直接 `rm -rf` 会因无法遍历而失败，导致重复打包时脚本在第一步
  就中断。脚本用 `find` 前序补 `u+rwx` 后再删。

### 3.3 包内布局

```
/opt/apps/<appid>/files/
  linglong_store            # Flutter runner（command 指向它）
  lib/                      # 引擎与插件；RPATH 为 $ORIGIN/lib
  data/                     # flutter_assets + icudtl.dat
  libexec/linglong_store_helper
  share/applications/<appid>.desktop
  share/icons/hicolor/256x256/apps/linglong-store.png
```

bundle 的相对布局必须原样保留：Flutter 引擎按可执行文件所在目录定位 `data/`，
特权 helper 也按可执行文件同级目录的 `libexec/` 定位
（`lib/core/platform/privileged_helper/privileged_helper_binary.dart`）。

## 4. 使用方式

```bash
# 完整链路（宿主执行：编译 + 装配 + 导出）
build/scripts/package-linyaps.sh --version 3.7.0 --arch amd64

# CI 复用已构建 bundle，跳过 Flutter 编译
build/scripts/package-linyaps.sh --version 3.7.0 --arch amd64 \
  --bundle-dir build/out/linux/3.7.0/amd64/bundle/linglong-store

# 指定 base
build/scripts/package-linyaps.sh --version 3.7.0 --arch amd64 \
  --base org.deepin.base/25.2.2
```

## 5. 运行时缺口（关键）

UAB 能装上、能浏览商品目录（走 HTTP `storeapi.linyaps.org.cn`），但**应用管理能力
全部不可用**，因为商店唯一的应用管理通道是 `ll-cli`，而它不存在于玲珑容器内
（约束 1）。逐项影响：

| 功能 | 容器内结果 | 代码位置 |
|------|-----------|---------|
| 启动环境检测 | 失败：`ll-cli 未安装或不可用` | `lib/application/services/linglong_environment_service.dart:65,75` |
| 已装列表 / 安装 / 升级 / 卸载 / 运行 / 结束 / 搜索已装 | `ll-cli` ENOENT | `lib/core/platform/cli_executor.dart:10,158`、`lib/data/repositories/linglong_cli_repository_impl.dart` |
| 免密安装（polkit 规则） | 物理不可能：无 pkexec，`/etc/polkit-1/rules.d` 在容器内不存在，且容器 `/etc` 非宿主 `/etc` | `lib/core/platform/polkit_rule_gateway.dart:26,404` |
| 特权 helper 通道 | 不可用：以 `pkexec` 拉起 | `lib/core/platform/privileged_helper/privileged_helper_client.dart:142` |
| 应用自更新 | 安全降级为「手动下载」（不会误判，但功能无用） | `lib/platform/self_update/linux_app_installation_probe.dart:53-77` |
| 单实例 | 可用（`$XDG_RUNTIME_DIR/<app-id>/` 文件锁 + socket） | `lib/core/platform/single_instance.dart:104-115` |

### 5.1 已确认可行的宿主通道

容器进程**可以**直连宿主系统总线上的 `org.deepin.linglong.PackageManager1`：
实测 `Introspect` 返回 `Install/InstallFromFile/Uninstall/Update/Prune/Search/SetConfiguration`，
且 `Properties.Get Configuration` 调用成功。宿主 polkit 策略
（`org.deepin.linglong.PackageManager1.policy`）要求 `auth_admin_keep`。

同类先例是 DeepSeek Harness 桌面客户端（`apps/linyaps/desktop-launcher`）：它在容器内
生成 `~/.dsh-linglong/bin/{ll-cli,ll-builder}` 包装脚本，经共享的用户会话总线用
`systemd-run --user` 把命令送回宿主执行，并用**子命令白名单**限制能力面
（`ll-cli` 只放 `list/info/content/analyze/ps/search`，`install/uninstall/upgrade` 明确拒绝）。
官方同类组件 `linyaps-web-store-installer` 则是 DEB/RPM 宿主机组件——生态惯例是
安装器留在沙箱外。

### 5.2 后续方案（待评审，未实施）

| 方案 | 说明 | 取舍 |
|------|------|------|
| A. UAB 降级为只读目录 | 按运行身份隐藏安装/卸载/更新入口，仅保留浏览，安装交给宿主 `og://` 处理器 | 改动小、风险低，但功能残缺 |
| B. UAB + 宿主机伴随组件 | 另发 DEB/RPM 提供宿主侧 bridge，复用 DSH 已验证的 `systemd-run` 通道 | 功能完整，但新增组件与信任边界，需安全评审 |
| C. UAB 直连守护进程 DBus | 用 `PackageManager1` 方法替代 `ll-cli` | 技术上可达，但需重写数据源，且容器进程发起 polkit 认证的可行性**未验证** |

### 5.3 与 DEB/RPM 形态共存：身份拆分

**问题（实测）**：早期版本两种形态共用同一应用 ID 与 desktop ID，在同一台机器上
共存会互相遮挡：

- 玲珑安装本身成功（`install uab successfully`），但
  `/usr/share/applications/com.dongpl.linglong-store.v2.desktop` **仍是 DEB 那份**
  （`dpkg -S` 确认归属 `linglong-store`，内容为 `Exec=linglong-store %u`），玲珑的
  `Exec=/usr/bin/ll-cli run ...` 没有覆盖它；
- `/var/lib/linglong/entries/share/applications/` 里没有本应用的条目，即玲珑侧没有
  导出自己的 desktop 入口；
- 结果启动器里只有一个图标，用户无法区分两个安装。

**解法**：玲珑轨道使用**独立应用身份** `LINYAPS_APPLICATION_ID`
（`config/application_identity.conf`），由它派生玲珑包的 `package.id`、desktop 文件名
与图标名。拆分后逐项对照：

| 身份项 | DEB/RPM/AppImage | 玲珑（UAB） |
|--------|------------------|-------------|
| 应用 ID | `com.dongpl.linglong-store.v2` | `com.dongpl.linglong-store.v2.linyaps` |
| desktop 文件名 | `…v2.desktop` | `…v2.linyaps.desktop` |
| 启动器名称 | 玲珑应用商店社区版 | 玲珑应用商店社区版**（玲珑版）** |
| 图标名 | `linglong-store` | `linglong-store-linyaps` |
| 数据目录 / 单实例锁 | `$XDG_*/…v2` | `$XDG_*/…v2.linyaps` |
| `StartupWMClass` | `com.dongpl.linglong-store.v2` | **同左（刻意相同）** |

`StartupWMClass` 必须保持主应用 ID：它由 runner 编译期写入
（`-DAPPLICATION_ID`），写别的值会让窗口与入口对不上、图标关联失效。

**遗留影响**：

1. 任务栏 / dock 若按 WM Class 归并，仍可能把两个窗口合成一个分组——彻底分开需要
   玲珑轨道用独立身份**编译** runner（第二条编译轨道），本次未做。
2. 数据目录分开意味着玲珑版首次启动没有 DEB 版的设置与日志；既有迁移机制只处理
   历史 ID 的一次性迁移，不跨形态复制。
3. 两个包都注册 `x-scheme-handler/og`，默认处理器只能有一个（后注册者生效）。

`package-linyaps.sh` 在打包时会提示另一种形态已安装，但不阻断。

## 6. 验收与未决问题

### 6.1 已验证

在 Deepin 25 + ll-builder 1.14.3 上完整跑通 `package-linyaps.sh --version 3.7.0
--arch amd64`，产物 `build/out/linux/3.7.0/amd64/linglong-store_3.7.0_amd64.uab`
（60 MiB，`ELF 64-bit LSB executable, statically linked, stripped`）。

| 验证项 | 结果 |
|--------|------|
| 发布容器编译 | 通过，`Impeller 关闭调用` 校验 PASS |
| 元数据渲染 | 通过，10 个 locale + 1 个兼容入口 |
| `ll-builder build` | 通过，`Successfully build com.dongpl.linglong-store.v2` |
| `ll-builder export`（默认模式） | 通过，erofs（lz4）内嵌进 UAB |
| **`ll-cli install`** | 通过，`install uab successfully`；`ll-cli list` 与 `ll-cli info` 均能读到 3.7.0.0 |
| `ll-cli uninstall` | 通过，`Uninstall main:.../3.7.0.0/x86_64 binary success` |
| **`--uabx` 模式（错误用法）** | 安装被拒：`Error -1: executable UAB installation is not supported` |
| 构建容器注入值 | `PREFIX=/opt/apps/<appid>/files`、`LINGLONG_APPID=<appid>`、`/project` = 调用目录 |
| 包内布局 | `files/linglong_store`(44 KB)、`files/lib/libapp.so`(9.8 MB)、`files/libexec/linglong_store_helper`(191 KB)、`files/data/*` 均在位 |
| 图标导出 | `entries/share/icons/hicolor/256x256/apps/linglong-store.png`(6.5 KB) 在位 |
| desktop 导出 | `entries/share/applications/com.dongpl.linglong-store.v2.desktop` 在位，含 `X-linglong` 标记与 10 个 locale 的 Name/GenericName |
| **`Exec` 改写** | 实际为 `Exec=/usr/bin/ll-cli run com.dongpl.linglong-store.v2 -- /opt/apps/com.dongpl.linglong-store.v2/files/linglong_store %u`——`%u` **被保留为独立参数**，`og://` 链路可用 |
| 调试符号 | `files/lib/debug` 在包内为空目录，剥离出的符号未进入 binary 模块（60 MiB 而非 bundle 的 122 MiB） |
| 工作树 | `ll-builder` 的 `linglong/` 状态目录只出现在 `build/tmp/` 下，仓库根目录未被污染 |

### 6.2 未验证

1. 容器进程发起 `Install` 时宿主 polkit 能否完成认证（容器 PID 命名空间与 polkit
   subject 解析）。
2. 应用 ID `com.dongpl.linglong-store.v2` 在玲珑远程仓库是否已被旧版 Tauri 商店占用
   （本机 `ll-cli search` 对已知包也返回未找到，该链路不可用）。
3. compat desktop 入口是否需要一并放进 `share/applications`（当前只放 canonical 一个）。
4. 玲珑 base 镜像在 loong64 上是否有对应版本。
5. `--bundle-dir` 复用路径下的产物与完整链路产物是否字节一致（应一致，未比对）。
6. UAB 已在本机安装成功，但**未启动过**：容器内 GTK3 运行时具备，窗口、字体、
   渲染的实际表现未验收。

## 7. 实施记录

新增文件：

- `build/packaging/linux/linyaps/linglong.yaml.in` —— 玲珑清单模板；
- `build/packaging/linux/linyaps/build.sh` —— 构建容器内的装配步骤（纯复制器）；
- `build/scripts/package-linyaps.sh` —— 宿主机编排入口；
- 本设计文档。

实测产物（2026-10-10，Deepin 25 / ll-builder 1.14.3）：

```
build/out/linux/3.7.0/amd64/linglong-store_3.7.0_amd64.uab
60 MiB  sha256=7baee75f81ff86f6e477d91122f116d935ddd19fd1cfaf9a21e1f916658a8d0b
```

产物不是字节可复现的：erofs 每次导出都会写入新的 UUID 与时间戳，同一输入两次导出
哈希不同。需要可复现性时应在 UAB 之外另附校验和，而不是比对两次导出的哈希。

排障记录（供后续维护参考）：

- `"$arr[0]"` 在双引号内**不会**解析为数组下标，会展开成 `${arr}` 加字面量 `[0]`；
  必须写 `"${arr[0]}"`。首次运行即因此失败，已修正。
- 首次实现误用 `export --uabx`，产出的是可执行 UABX，`ll-cli install` 直接拒绝
  （`executable UAB installation is not supported`）。已改为默认导出模式，并实测
  卸载后重装成功。
- 首次探测 `ll-builder` 时在仓库根目录留下了未跟踪的 `linglong/` 状态目录。
  正式脚本固定 `cd` 到 `build/tmp/` 下的暂存目录，从设计上避免该问题。
- `ll-builder` 的 overlay workdir 权限为 `0000`，导致重复打包时 `rm -rf "$stage_root"`
  在第一步就失败（第二次运行时实际踩到）。已改为先 `find ... -exec chmod u+rwx` 再删。

未纳入本次改动（后续可选）：

- `build/scripts/package-smoke-test.sh` 未加入 linyaps 步骤：它需要 CI runner 具备
  `ll-builder` 与宿主玲珑守护进程，属于 CI 侧决策。
- `.github/workflows` 未接入 linyaps 发版。
