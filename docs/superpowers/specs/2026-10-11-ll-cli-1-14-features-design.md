# ll-cli 1.14 空间分析、依赖清理与镜像地区适配设计

日期：2026-10-11。状态：用户已确认沿用现有入口的集成方案。

## 目标与边界

在现有 Linux 商店中集成自动清理偏好、空间与依赖分析、镜像地区选择，保持界面响应和既有安装授权路径。所有新入口只在实际检测到 ll-cli 1.14.0 或更高版本时显示；版本未知、无效或低于门槛时隐藏，并且不执行分析命令、不下发新参数。既有旧版本安装、手动清理和镜像开关继续按原契约工作。

源码依据为 `/home/han/code/linyaps`，2026-10-11 执行 `git pull --ff-only` 后 HEAD 为 `0fee1e07d6b465ed3259822538189f2c5ecccae6`。分别检查 `1.13.0` 与 `1.14.0` 标签：后者含 `analyze`、`--no-auto-prune` 和镜像 `--region`，前者不含这些新增能力。开发分支 CMake 声明 1.15.0，不能用 master 的项目版本或 git describe 代替功能引入版本。

不使用 worktree；在当前工作目录的功能分支实施。现有未跟踪文件不纳入提交。文档和代码均使用中文业务注释，遵守方向感知布局、无障碍和项目统一菜单约定。

## 已确认的上游契约

### 空间分析

真实命令：`ll-cli --json analyze size`，无 APP 参数。可附加 `--sort actual|logical|exclusive|shared|id` 与 `--asc`。该命令扫描全部未删除的已安装模块，并遍历仓库；只允许按需执行和复用快照，不得逐卡片调用或启动轮询。

JSON 根对象包含：

```json
{
  "modules": [{
    "id": "org.example.app", "name": "Example", "version": "1.0.0",
    "channel": "main", "module": "binary",
    "exclusiveSize": 4096, "sharedSize": 8192,
    "logicalSize": 12288, "actualSize": 8192
  }],
  "calculatedLogicalSize": {
    "exclusiveSize": 4096, "sharedSize": 8192, "logicalSize": 12288
  },
  "calculatedActualSize": 8192,
  "repositoryRealSize": 16384
}
```

字节数必须是非负整数，缺字段或错误对象不得当成空结果。模块没有 arch、kind、repo 字段，不能按应用 ID 取第一条并冒充精确架构统计。应用详情按本地已安装身份的 ID/version/channel 展示对应模块；遇到身份歧义保留模块列表，不推断额外身份。

四个维度的定义来自 `cli.cpp` 的 inode 扫描：

- 独占：只被一个已安装模块使用的数据块。
- 共享：多个模块共享的数据块，在各模块中完整计入。
- 逻辑：独占加共享，使用 `st_blocks * 512`，不是文件长度之和。
- 实际：共享块按使用模块数分摊后的估算占用。

全局已安装模块的实际总量直接使用 `calculatedActualSize`，不累加分摊值；仓库真实占用使用 `repositoryRealSize`，不以两者差值推断可清理空间。独占也不能承诺为卸载可释放空间。

### 依赖关系

真实命令：`ll-cli --json analyze depends [APP]`。APP 支持已安装应用的完整 reference。JSON 根为数组，节点结构是 `{ref, kind, children}`，原始方向是 base → runtime → app，extension 挂在所属节点下。界面展示“应用使用的环境”并保留原始依赖层级，不能将 app 子节点解释成它的基础依赖。

查询单个应用时优先使用本地精确身份，不用商店后端最新版本替代已安装版本。未安装应用不提供本地分析入口。分析失败保留完整可复制诊断与重试操作。

### 自动清理

`install`、`upgrade`、`uninstall` 均支持 `--no-auto-prune`，默认 false。该参数只跳过未使用依赖清理；普通 OSTree 不可达对象回收继续执行。旧应用替换在清理之前发生，因此界面不能称为“保留所有历史版本”。

清理由 package-manager 在发生相关替换、升级或主模块卸载后执行，首次全新安装不保证触发。自动清理失败只记日志，不改变原操作成功状态；没有节省字节或清理包列表回传。商店不额外接一次 prune，也不显示虚构的清理进度或节省空间。

### 镜像地区

`repo enable-mirror ALIAS --region CODE` 写入 `mirror_enabled=true` 与 `region`。不传 region 会清除旧地区；disable 只关闭镜像并保留地区。JSON 使用 `mirror_enabled` 与 `region`，缺字段或文本回退均为未知状态，不能自动当成 false。

界面提供自动、CN、US、EU 和自定义代码。上游没有地区白名单，这些只是快捷选项，不承诺服务端存在对应镜像。自动表示不指定地区、交由服务端选择，不承诺最快或失败自动回源。自定义只接受安全地区代码字符，拒绝空格及 `&/?#` 等 URL 查询字符；上游直接拼接 region，不能原样接受任意文本。

关闭镜像后再次开启，显式传回已保存地区；只有用户选择自动才清除。配置写入后回读确认：回读失败显示“设置已提交，状态尚未确认”，不得显示成功切换。地区选择影响后续下载，不修改商店后端仓库参数或原仓库地址。

## 分层与数据流

### 统一版本门槛

新增纯 Domain `LinglongCliCapabilities.fromVersion(String?)`，从启动检测所得原始 CLI 版本提取版本号。Application 提供单一 `linglongCliCapabilitiesProvider`；页面只读能力布尔值。格式无法识别时保守隐藏。测试覆盖 1.13、1.14、1.15、版本前缀、构建后缀和未知值。

### 自动清理策略

`SettingState.autoPruneDependencies` 默认为 true，SharedPreferences 持久化。单次/批次入队冻结 `InstallTask.noAutoPrune`；旧 Journal 缺字段恢复为 false，人工重试保留原值。任务执行器将快照传给 Repository，helper NDJSON 与 C++ 参数构造同步支持可选布尔字段。省略或 false 保持旧协议兼容；true 才追加新旗标。卸载仍统一经 AppUninstallService，由组合入口读取一次能力和偏好后调用 CLI。

UI 在设置页显示“自动清理未使用依赖”，默认开启，描述准确说明关闭后影响后续操作。手动清理仍需用户确认，不受此偏好限制，并刷新已安装列表和空间快照。旧 CLI 即使保存了关闭偏好，也不发送不支持的参数。

### 分析边界

新增 `LinglongAppAnalysisRepository` 作为独立只读接口，由 Data 实现复用现有 CliExecutor，不扩充大而全的安装 Repository。只解析 JSON，重解析移入后台 isolate。生产实现只在 bootstrap 装配，Application 不依赖具体 Data 类。

全量空间结果由单一 Application Provider 持有，合并并发请求，缓存有时效；安装、升级、卸载、手动清理完成以及保存位置迁移后失效。缓存失效不会在隐藏页面自动扫描。请求期间发生失效时，旧结果不得覆盖新状态。刷新保留已显示结果，并标记正在更新；首载单独显示有语义标签的加载状态。

应用依赖由独立按精确 reference 组织的异步 Provider 获取。只在分析面板打开时查询，关闭释放订阅；空间和依赖分别呈现失败状态，一项失败不遮挡另一项。

## 界面与交互

- 环境管理增加“空间分析”页签，仅在版本满足门槛时存在。首次切换才执行扫描。顶部显示仓库真实占用与模块实际总量，下面是搜索、维度排序和 builder 模块列表。
- 应用详情的应用信息区域增加“空间与依赖”入口，打开受约束的分析对话框；空间与依赖使用分段页签，显示真实已安装版本。
- 四维信息使用紧凑指标和明细行，实际标注为分摊口径；不把四项绘成可相加的四段进度条。
- 仓库行显示镜像状态、地区选择。使用既有 AppAnchoredMenu；设置过程中禁用重复提交，失败保留原确认状态。
- 复用系统主题颜色、8px 圆角与项目字体令牌，适配深浅主题、窄窗口、大字体和 RTL；使用现有无障碍按钮与焦点隔离封装。
- 错误有 Tooltip、完整复制与重试，状态标签全部国际化；界面不展示实现说明或内部 CLI 命令。

## 实施与验收

独立提交：设计与计划；版本门槛及自动清理；空间/依赖分析；镜像地区。每个功能包含必要业务文档更新和测试。

窄测试覆盖版本隐藏、参数快照与重试、helper 类型校验及参数构造、真实 JSON 解析、错误对象、缓存并发与失效、精确应用匹配、镜像回读与地区清除/保留。Widget 验证新旧版本入口、加载/空/错误状态、搜索排序、地区选择、键盘、RTL 和窄窗口不溢出。最终运行 `flutter analyze`、关键单元/Widget 测试及方向性检查；具备运行条件时做 Linux 构建和界面检查，真实系统验证不修改开发机包或策略。

业务变更写入 CHANGELOG.md，版本兼容与空间口径同步到现有环境管理设计文档。
