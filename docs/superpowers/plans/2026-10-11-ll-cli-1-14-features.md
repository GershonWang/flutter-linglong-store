# ll-cli 1.14 新能力实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 subagent-driven-development 或 executing-plans 逐任务实施。用户已确认整体方案并要求实施，任务间不重复请求方案批准。

**Goal:** 为 ll-cli 1.14.0+ 提供空间/依赖分析、自动清理偏好和地区镜像选择。

**Architecture:** 沿用 Riverpod 分层和现有命令执行器；只读分析独立 Repository，安装与仓库操作扩展现有接口。所有新增界面与参数通过统一 CLI 版本能力控制。

**Tech Stack:** Flutter Linux、Riverpod、Freezed、SharedPreferences、C++ 特权 helper。

**Spec:** `docs/superpowers/specs/2026-10-11-ll-cli-1-14-features-design.md`

## Global Constraints

- 最低版本 ll-cli 1.14.0，低版/未知不展示新增功能、不发送新参数。
- 不使用 worktree，不修改已有无关未跟踪文件；用户于收尾阶段明确要求提交并 push，仅推送当前功能分支，不自动合并或创建 PR。
- 分析按需执行，不轮询，不在 build 中解析/排序/IO；使用 builder 列表。
- 中文业务注释；方向感知布局；菜单复用 AppAnchoredMenu；无障碍和国际化。
- `--no-auto-prune` 不承诺保留所有历史应用版本；分摊占用不承诺可释放空间。
- 使用现有授权路径，helper 仅增加类型化布尔参数，不接收任意 argv。

## Task 1: 版本门槛与自动清理策略

**Files:**
- Create: `lib/domain/models/linglong_cli_capabilities.dart`
- Create: `lib/application/providers/linglong_cli_capabilities_provider.dart`
- Modify: `lib/application/providers/setting_provider.dart`
- Modify: `lib/domain/models/install_task.dart`
- Modify: `lib/domain/repositories/linglong_cli_repository.dart`
- Modify: `lib/application/providers/install_queue_provider.dart`
- Modify: `lib/application/services/app_operation_task_executor.dart`
- Modify: `lib/application/providers/app_uninstall_provider.dart`
- Modify: `lib/data/repositories/linglong_cli_repository_impl.dart`（安装/更新/卸载区）
- Modify: `lib/core/platform/privileged_helper/privileged_helper_protocol.dart`
- Modify: `linux/privileged_helper/helper_protocol.*`、`helper_task_runner.*`、`helper_main.cc`
- Modify: 设置页、对应生成代码与测试替身。

**Interfaces:**
- Produces: `LinglongCliCapabilities.fromVersion(String?)`，`supportsDiskAnalysis`、`supportsAutoPruneControl`、`supportsMirrorRegion`。
- Produces: `linglongCliCapabilitiesProvider`；`SettingState.autoPruneDependencies`；`InstallTask.noAutoPrune` 默认 false。
- Extends: `installApp(..., bool noAutoPrune = false)`、`updateApp(String, {bool noAutoPrune = false})`、`uninstallApp(String, String?, {bool noAutoPrune = false})`。

- [x] 用真实 CLI 版本字符串写门槛测试：`linyaps CLI version 1.13.0` 为 false，`linyaps CLI version 1.14.0` 为 true，`1.14.2+hash` 为 true，null/空/无效为 false。命令：`flutter test test/unit/domain/models/linglong_cli_capabilities_test.dart`，以测试固定兼容边界。
- [x] 实现纯版本能力模型，Application 从启动环境状态派生；页面不自行比较字符串。
- [x] 添加命令测试，验证关闭清理时三个操作只追加一个 `--no-auto-prune`，开启时保持现有 argv；helper optional bool 类型不合法时拒绝。

```dart
await repository.installApp('org.example.demo', noAutoPrune: true).drain<void>();
expect(executor.progressCalls.single,
    ['install', '--json', 'org.example.demo', '--no-auto-prune']);
```

- [x] 增加设置持久化、入队/批次快照、人工重试保留与卸载统一入口的参数透传；旧版门槛只允许 false。
- [x] 同步 Dart/C++ helper 可选字段与测试；保持 false 请求兼容旧协议。
- [x] 更新生成代码，执行版本、队列、CLI 参数、helper、设置 Widget 测试；代码审查后提交 `feat: 适配玲珑自动清理偏好与版本门槛`。

## Task 2: 空间和依赖分析

**Files:**
- Create: `lib/domain/models/linglong_app_analysis.dart`
- Create: `lib/domain/repositories/linglong_app_analysis_repository.dart`
- Create: `lib/data/repositories/linglong_app_analysis_repository_impl.dart`
- Create: `lib/application/providers/linglong_app_analysis_provider.dart`
- Create: `lib/presentation/widgets/linglong_app_analysis_dialog.dart`
- Create: `lib/presentation/widgets/linglong_environment_management/disk_analysis_tab.dart`
- Modify: `lib/application/providers/application_dependency_providers.dart`、`lib/bootstrap/production_dependency_overrides.dart`
- Modify: 环境管理对话框/页签、应用详情信息区域、操作后同步入口。
- Test: 同名 Domain/Data/Application/Widget 测试。

**Interfaces:**
- Consumes: Task 1 的统一版本能力 Provider。
- Produces: `LinglongDiskUsage`、`LinglongModuleUsage`、`LinglongDependencyNode`。
- Produces: `LinglongAppAnalysisRepository.analyzeSize()` 与 `.analyzeDepends(String appRef)`。
- Produces: `linglongDiskAnalysisProvider` 按需 load/refresh/invalidate；`linglongAppDependenciesProvider` 按 reference 缓存。

- [x] 根据 Spec 的完整 JSON fixture 写解析测试，覆盖零值、错误根对象、缺失字段、负数和反向依赖树；以测试固定真实上游字段和依赖方向。

```dart
expect(usage.calculatedActualSize, 8192);
expect(usage.modules.single.sharedSize, 8192);
expect(nodes.single.kind, 'base');
expect(nodes.single.children.single.kind, 'runtime');
```

- [x] 实现只读 Repository，复用 CliExecutor；只执行 `['--json','analyze','size']` 和 `['--json','analyze','depends',appRef]`。解析在后台 isolate，异常保持可复制诊断。
- [x] 实现合并请求/五分钟缓存/显式失效，失效期间旧扫描不得重新成为有效缓存；旧版拒绝执行。Provider 测试通过 Completer 控制并发时序。
- [x] 实现环境管理空间页签与应用详情对话框。首开才 load；搜索、排序作用于缓存模块，切换不重新扫描。依赖展示使用真实本地 reference。
- [x] 按实际操作结果失效缓存，隐藏页面不重跑分析；手动清理后刷新已安装列表。
- [x] Widget 覆盖旧版隐藏、首载、刷新保留、空结果、单项失败、搜索排序、窄窗口和 RTL；审查后提交 `feat: 增加玲珑空间与依赖分析`。

## Task 3: 镜像地区与透明状态

**Files:**
- Modify: `lib/domain/models/linglong_env_check_result.dart` 及生成代码。
- Modify: `lib/domain/repositories/linglong_repository_management_repository.dart`
- Modify: `lib/data/repositories/linglong_cli_repository_impl.dart`（repo 解析和 mirror 区）
- Modify: `lib/application/services/linglong_environment_service.dart`
- Modify: `lib/application/providers/linglong_environment_management_provider.dart`
- Modify: `lib/presentation/widgets/linglong_environment_management/repository_management_tab.dart`
- Modify: `lib/presentation/widgets/linglong_environment_management/environment_management_dialog_actions.dart`
- Test: 仓库命令/环境管理 Provider/镜像行 Widget 测试。

**Interfaces:**
- Consumes: Task 1 的 `supportsMirrorRegion`。
- Extends: `LinglongRepoInfo` nullable `isMirrorEnabled` 与 `region`。
- Extends: `setRepositoryMirror(String, {required bool enabled, String? region})`。

- [x] 添加 repo JSON 读取 mirror_enabled/region 和 argv 测试；文本回退的镜像状态应为 null。

```dart
expect(repo.isMirrorEnabled, isTrue);
expect(repo.region, 'CN');
expect(argv, ['repo','enable-mirror','stable','--region','CN']);
```

- [x] 扩展两处仓库读取映射与统一写接口；disable 不发送 region，自动选择不发送 region，重新开启保留已存地区。
- [x] 写入后严格回读，失败保留诊断并显示未确认状态，避免成功通知掩盖配置读取失败。
- [x] 增加开关/地区菜单与自定义输入，安全校验地区字符；旧版只保留已有镜像开关操作。
- [x] 测试选择 CN/US/EU/自动、自定义非法输入、旧版隐藏、失败回读和连续操作；审查后提交 `feat: 支持玲珑镜像地区选择`。

## Task 4: 本地化、整体验证和交付

**Files:** 各语言 ARB、对应生成本地化、`docs/21-linglong-environment-management.md`、`CHANGELOG.md`。

- [x] 每个功能的新增文案在该功能测试前补齐所有支持语言，不在业务模型中保存本地化文本。
- [x] 执行相关单元/Widget 测试、`dart run build/scripts/verify_directional_layout.dart`、`flutter analyze`。新的失败最多尝试三轮，记录实际环境限制。
- [x] Linux 构建与视图检查：确认窄窗口、深浅主题、长名称、RTL 无溢出，加载与刷新不阻塞交互。真实系统命令只做只读查询。
- [x] 用独立审查检查版本门槛、源码统计口径、helper 参数边界和缓存生命周期，处理有效问题。
- [x] 更新本计划的完成记录、设计文档与 CHANGELOG，核实提交和工作区只留下原有无关文件。交付功能入口、最低版本、验证结果与真实环境未覆盖项。

## 执行记录

- 2026-10-11：用户批准现有入口方案；最低版本按 1.13.0/1.14.0 源码标签核实为 1.14.0。
- 2026-10-11：在现有目录创建 `codex/ll-cli-1-14-features` 分支，不使用 worktree。

### 完成记录

- 版本兼容与自动清理：`4df6a86`、`a60f2a8`、`fd50c5b`；补充队列、失败反馈及统一卸载透传测试。最低正式版本为 1.14.0，保留原始预发布后缀，未知版本不猜测能力。
- 空间与依赖分析：`4a87490`。后台解析、五分钟缓存、单飞查询、失效时序、真实本地身份和独立错误反馈已实现。独立审查发现的诊断截断、能力撤销后的加载状态和长语言页签溢出已修复。
- 地区镜像：`2ad7869`。严格回读、未知状态、CN/US/EU/自动/安全自定义及旧版入口已完成。独立审查发现的未知地区误标为自动、未确认快照导致旧地区回写已修复；自定义表单控制器由路由中的 StatefulWidget 管理，关闭动画不提前释放。
- 全量测试：`PATH=/home/han/flutter/bin:$PATH flutter test` 最终 1316 项通过、11 项跳过；跳过项维持现有测试条件，没有新增功能失败。镜像窄回归 33 项、C++ helper 75 项检查均通过。
- 静态与构建：`flutter analyze` 无问题；方向布局门禁通过；最终 `flutter build linux --release` 成功，产物为 `build/linux/x64/release/bundle/linglong_store`。
- 真实系统只读验收：本机 ll-cli 1.14.0 的 `repo show`、`list`、`analyze size` 与精确相机 reference 的 `analyze depends` 成功。空间输出含 24 个模块，实际去重总量及仓库总量被生产 Repository 正确解析；依赖输出保留 base→runtime→app 层级。注入捕获输出的临时验收测试通过，不重复扫描仓库。
- 视图验收：正式 AppTheme 与 MaterialIcons 的 Widget 截图已检查，覆盖浅色、深色、RTL、420px 窄窗口和 1.5 倍字体；仓库地区菜单无文字或图标遮挡。临时截图与真实系统输出位于 `/tmp/`，不纳入仓库。
- 验收边界：未对开发机执行真实镜像切换、安装、升级、卸载或清理，也未测量实际下载加速、Profile 内存/帧率或覆盖率百分比；不把自动化测试通过表述为这些指标已达标。用户可使用 Release 产物进行最终真实操作验收。
- 交付：设计文档、现有环境管理文档与 CHANGELOG 已同步；原有 `GITHUB_ACTIONS_ISSUES.md` 和两个 `__pycache__/` 目录保持不变，不纳入提交。按用户新指令推送 `codex/ll-cli-1-14-features`，远端结果以实际 push 与 ref 回读为准。
