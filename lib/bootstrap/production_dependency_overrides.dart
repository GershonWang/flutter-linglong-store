/// 组装正式运行环境所需的 Data、Platform 和外部资源实现。
///
/// 这是生产依赖的唯一组合根；业务 Provider 只读取 Application 端口，不得在
/// 其他位置重新创建 Repository、Journal 或系统通知具体实现。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

import '../application/providers/application_dependency_providers.dart';
import '../application/providers/polkit_rule_provider.dart';
import '../application/providers/runtime_form_provider.dart';
import '../core/logging/app_logger.dart';
import '../core/platform/file_downloader.dart';
import '../core/platform/host_escape_channel.dart';
import '../core/platform/linglong_cli_command.dart';
import '../core/platform/polkit_rule_gateway.dart';
import '../core/platform/privileged_helper/privileged_helper_client.dart';
import '../core/platform/shell_command_executor.dart';
import '../core/storage/app_xdg_paths.dart';
import '../data/repositories/analytics_repository_impl.dart';
import '../data/repositories/app_repository_impl.dart';
import '../data/repositories/error_solution_repository_impl.dart';
import '../data/repositories/file_app_operation_journal_repository.dart';
import '../data/repositories/linglong_cli_repository_impl.dart';
import '../data/repositories/shared_preferences_legacy_app_operation_state_repository.dart';
import '../domain/models/privileged_helper_trust.dart';
import '../domain/repositories/app_self_update_gateways.dart';
import '../platform/appearance/linux_system_accent_color_gateway.dart';
import '../platform/notifications/linux_system_notification_gateway.dart';
import '../platform/self_update/linux_app_installation_probe.dart';
import '../platform/self_update/linux_app_update_installers.dart';
import '../platform/self_update/xdg_app_update_workspace.dart';

/// 创建正式应用根 ProviderScope 使用的完整依赖覆盖。
///
/// [sharedPreferences] 必须由 main 在数据迁移和 PreferencesService 初始化完成后
/// 传入，避免组合根自行破坏启动顺序。
List<Override> createProductionDependencyOverrides({
  required SharedPreferences sharedPreferences,
}) {
  // 自更新的系统命令统一复用一个无状态执行器，避免三个安装适配器各自创建边界。
  final selfUpdateCommandExecutor = ShellCommandExecutor();
  final selfUpdateNetworkClient = Dio();

  // 特权 helper 会话是应用生命周期单例（docs/47 §4.3）：install/update 的
  // 首次授权一次、后续复用都依赖同一进程句柄；两个 CLI Repository 覆盖共享
  // 同一客户端，防止 autoDispose 重建实例时重复拉起 pkexec。
  final privilegedHelper = PrivilegedHelperClient();

  // 运行形态决定 ll-cli 的命令形态，也决定哪些特权能力必须提前降级；必须在任何
  // Repository/Service 发起调用之前定好（它们是调用时读取）。
  final runtimeForm = _configureLinglongCliCommandForm();

  return [
    linglongRuntimeFormProvider.overrideWithValue(runtimeForm),
    sharedPreferencesProvider.overrideWithValue(sharedPreferences),
    appRepositoryProvider.overrideWith((ref) => AppRepositoryImpl()),
    analyticsRepositoryProvider.overrideWith(
      (ref) => AnalyticsRepositoryImpl(),
    ),
    errorSolutionRepositoryProvider.overrideWith(
      (ref) => ErrorSolutionRepositoryImpl(),
    ),
    linglongCliRepositoryProvider.overrideWith((ref) {
      return LinglongCliRepositoryImpl(
        privilegedHelper: privilegedHelper,
        // 只读模式读取器在任务启动时取一次快照并绑定到该任务（docs/50 §7.1）。
        passwordFreeInstallModeReader: ref.read(
          passwordFreeInstallModeReaderProvider,
        ),
        // 信任解析器在任务启动时解析一次并绑定到该任务（docs/51 §4.2）。
        helperTrustResolver: ref.read(privilegedHelperTrustResolverProvider),
      );
    }),
    linglongRepositoryManagementRepositoryProvider.overrideWith((ref) {
      return LinglongCliRepositoryImpl(privilegedHelper: privilegedHelper);
    }),
    appOperationJournalRepositoryProvider.overrideWith((ref) {
      final journalPath = AppXdgPaths.resolveOperationJournalFilePath();
      if (journalPath == null) {
        throw StateError('无法解析 XDG 应用操作 Journal 路径');
      }
      return FileAppOperationJournalRepository(File(journalPath));
    }),
    legacyAppOperationStateRepositoryProvider.overrideWith(
      (ref) =>
          SharedPreferencesLegacyAppOperationStateRepository(sharedPreferences),
    ),
    systemNotificationGatewayProvider.overrideWith(
      (ref) => const LinuxSystemNotificationGateway(),
    ),
    systemAccentColorGatewayProvider.overrideWith(
      (ref) => const LinuxSystemAccentColorGateway(),
    ),
    appInstallationProbeProvider.overrideWith((ref) {
      return LinuxAppInstallationProbe(
        shellExecutor: selfUpdateCommandExecutor,
      );
    }),
    appUpdateWorkspaceFactoryProvider.overrideWith((ref) {
      return XdgAppUpdateWorkspaceFactory(
        downloader: FileDownloader(dio: selfUpdateNetworkClient),
      );
    }),
    appUpdateInstallersProvider.overrideWith((ref) {
      return <AppUpdateInstaller>[
        DpkgAppUpdateInstaller(selfUpdateCommandExecutor),
        RpmAppUpdateInstaller(selfUpdateCommandExecutor),
        AppImageAppUpdateInstaller(selfUpdateCommandExecutor),
      ];
    }),
    // 免密规则提权同步：唯一配置入口，独立于安装传输用的特权 helper
    // （docs/50 §6.1）。执行器无状态，随组合根创建一次即可。
    polkitRuleGatewayProvider.overrideWith((ref) {
      return PolkitRuleScriptGateway(executor: ShellCommandExecutor());
    }),
    // Data 层不得反向导入 Application Provider：这里只注入一个同步只读函数，
    // 任务启动时读取控制器内存状态，不做 IO、不提权（docs/50 §7.1）。
    passwordFreeInstallModeReaderProvider.overrideWith((ref) {
      return () => ref.read(polkitRuleProvider).usesPasswordFreeCli;
    }),
    // docs/51：helper 来源信任判定——单次解析 + 会话内缓存；解析异常保守
    // 返回 false（fail closed），统一由构造器实现。
    privilegedHelperTrustResolverProvider.overrideWith((ref) {
      return buildMemoizedHelperTrustResolver(
        ref.watch(appInstallationProbeProvider),
      );
    }),
  ];
}

/// 按运行形态安装 ll-cli 命令构造器，并返回本次进程的运行形态。
///
/// 玲珑（UAB）形态下容器里没有 ll-cli，也没有宿主的玲珑守护进程与层仓库，
/// 因此把命令透传到宿主执行；其它形态（DEB / RPM / AppImage / 开发态）保持本地
/// 直调，行为与收敛前完全一致。
///
/// 探测失败或宿主未装玲珑时**保持本地直调**而不是静默失败：既有的"ll-cli 未安装
/// 或不可用"诊断路径会照常给出可读错误，比在这里悄悄降级更好定位。
///
/// 安全提示：透传是沙箱逃逸通道，能力面由 [BridgedLinglongCliCommandBuilder] 承载的
/// 命令决定。本函数只接入 ll-cli，不接入 pkexec 等提权命令（见 docs/60 §7）。
LinglongRuntimeForm _configureLinglongCliCommandForm() {
  final channel = HostEscapeChannel.detect();
  if (channel == null) {
    AppLogger.info('[HostBridge] 未检测到宿主透传通道，ll-cli 走本地直调');
    return LinglongRuntimeForm.hostInstalled;
  }

  final hostLlCli = channel.hostExecutable('ll-cli');
  if (hostLlCli == null) {
    AppLogger.warning('[HostBridge] 宿主上未找到 ll-cli，保持本地直调');
    return LinglongRuntimeForm.hostInstalled;
  }

  configureLinglongCliCommandBuilder(
    BridgedLinglongCliCommandBuilder(
      channel: channel,
      hostLlCliPath: hostLlCli,
    ),
  );
  AppLogger.info(
    '[HostBridge] ll-cli 透传到宿主执行: $hostLlCli（工作目录 ${channel.workingDirectory}）',
  );
  return LinglongRuntimeForm.linglongContainer;
}

/// 构造 helper 信任解析器：单次解析 + 会话内缓存（docs/51 §4.2）。
///
/// 探测会启动系统命令，同一会话只应执行一次；解析异常在这里就保守返回
/// false 并随缓存复用（不得失败开放），Data 层的兜底捕获只是第二道防线。
PrivilegedHelperTrustResolver buildMemoizedHelperTrustResolver(
  AppInstallationProbe probe,
) {
  Future<bool>? resolved;
  return () => resolved ??= _resolveHelperTrust(probe);
}

Future<bool> _resolveHelperTrust(AppInstallationProbe probe) async {
  try {
    return await probe.isManagedBySystemPackageManager();
  } catch (error, stackTrace) {
    AppLogger.warning('[HelperTrust] 包管理器归属探测失败，按不可信处理', error, stackTrace);
    return false;
  }
}
