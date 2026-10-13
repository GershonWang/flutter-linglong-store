/// 商店启动及玲珑环境恢复编排。
///
/// 网络浏览所需的上下文与本机玲珑能力分开准备；环境缺失时先进入商店，
/// 环境修复后只补做一次本机初始化，避免启动页阻塞及重复 CLI 请求。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/config/app_config.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/models/linglong_env_check_result.dart';
import 'application_dependency_providers.dart';
import 'app_operation_lifecycle_coordinator.dart';
import 'app_search_index_provider.dart';
import 'global_provider.dart';
import 'installed_app_diff_report_provider.dart';
import 'installed_apps_provider.dart';
import 'install_queue_provider.dart';
import 'linglong_env_provider.dart';
import 'update_apps_provider.dart';

part 'launch_provider.g.dart';

/// 启动阶段解析应用版本号。
///
/// 单测可覆盖该 Provider，以避免直接依赖平台 channel。
final launchAppVersionResolverProvider = Provider<Future<String> Function()>((
  ref,
) {
  return () async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version.trim();
    } catch (_) {
      return AppConfig.appVersion;
    }
  };
});

/// 启动步骤枚举
enum LaunchStep {
  /// 环境检测
  environmentCheck,

  /// 已安装应用初始化
  installedAppsInit,

  /// 更新检查
  updateCheck,

  /// 安装队列恢复
  queueRecovery,

  /// 完成
  completed,

  /// 错误
  error,
}

/// 启动步骤信息
class LaunchStepInfo {
  const LaunchStepInfo({required this.step, required this.message, this.error});

  final LaunchStep step;
  final String message;
  final String? error;

  LaunchStepInfo copyWith({LaunchStep? step, String? message, String? error}) {
    return LaunchStepInfo(
      step: step ?? this.step,
      message: message ?? this.message,
      error: error ?? this.error,
    );
  }
}

/// 启动状态
class LaunchState {
  const LaunchState({
    this.currentStep = LaunchStep.environmentCheck,
    this.progress = 0.0,
    this.stepInfo = const LaunchStepInfo(
      step: LaunchStep.environmentCheck,
      message: '正在检测环境...',
    ),
    this.isCompleted = false,
    this.isBrowseOnly = false,
    this.hasError = false,
    this.errorMessage,
    this.installedAppsCount = 0,
    this.pendingTasksCount = 0,
  });

  /// 当前步骤
  final LaunchStep currentStep;

  /// 进度 (0.0 - 1.0)
  final double progress;

  /// 步骤信息
  final LaunchStepInfo stepInfo;

  /// 是否完成
  final bool isCompleted;

  /// 已完成启动，但本机玲珑能力尚未初始化。
  ///
  /// 此状态仍允许进入所有在线浏览页面；恢复后由同一个启动编排器清除。
  final bool isBrowseOnly;

  /// 是否有错误
  final bool hasError;

  /// 错误信息
  final String? errorMessage;

  /// 已安装应用数量
  final int installedAppsCount;

  /// 待处理任务数量
  final int pendingTasksCount;

  /// 获取步骤进度权重
  static const Map<LaunchStep, double> stepWeights = {
    LaunchStep.environmentCheck: 0.3,
    LaunchStep.installedAppsInit: 0.5,
    LaunchStep.updateCheck: 0.1,
    LaunchStep.queueRecovery: 0.1,
    LaunchStep.completed: 0.0,
    LaunchStep.error: 0.0,
  };

  /// 计算当前总进度
  double get totalProgress {
    if (isCompleted) return 1.0;
    if (hasError) return progress;

    double total = 0.0;
    const steps = LaunchStep.values;

    for (int i = 0; i < steps.length; i++) {
      if (steps[i] == currentStep) {
        total += stepWeights[currentStep]! * progress;
        break;
      }
      total += stepWeights[steps[i]] ?? 0;
    }

    return total.clamp(0.0, 1.0);
  }

  LaunchState copyWith({
    LaunchStep? currentStep,
    double? progress,
    LaunchStepInfo? stepInfo,
    bool? isCompleted,
    bool? isBrowseOnly,
    bool? hasError,
    String? errorMessage,
    int? installedAppsCount,
    int? pendingTasksCount,
    bool clearError = false,
  }) {
    return LaunchState(
      currentStep: currentStep ?? this.currentStep,
      progress: progress ?? this.progress,
      stepInfo: stepInfo ?? this.stepInfo,
      isCompleted: isCompleted ?? this.isCompleted,
      isBrowseOnly: isBrowseOnly ?? this.isBrowseOnly,
      hasError: clearError ? false : (hasError ?? this.hasError),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      installedAppsCount: installedAppsCount ?? this.installedAppsCount,
      pendingTasksCount: pendingTasksCount ?? this.pendingTasksCount,
    );
  }
}

/// 启动序列 Provider
///
/// 管理应用启动时的初始化序列：
/// 1. 环境检测 - 检查 ll-cli 是否可用
/// 2. 网络浏览上下文 - 缺少环境也准备架构、版本与用户允许的统计上下文
/// 3. 环境可用时加载本机列表、检查更新及恢复安装队列
/// 5. 完成后跳转到主页
@Riverpod(keepAlive: true)
class LaunchSequence extends _$LaunchSequence {
  @override
  LaunchState build() {
    // 环境安装可能发生在设置页或功能门禁弹窗，恢复不能依赖已销毁的启动页。
    ref.listen<LinglongEnvState>(linglongEnvProvider, (previous, next) {
      if (state.isCompleted && next.isUnavailable) {
        // 运行中环境再次失效时保留首页，只作废本机初始化；修复后重建被清理的快照。
        _runtimeInitialized = false;
        if (!state.isBrowseOnly) {
          state = state.copyWith(isBrowseOnly: true);
        }
      }
      if (state.isCompleted &&
          state.isBrowseOnly &&
          (next.result?.isOk ?? false) &&
          !(previous?.result?.isOk ?? false)) {
        unawaited(continueAfterEnvCheck());
      }
    });
    return const LaunchState();
  }

  /// 合并重复启动请求，避免页面回调与重试并发执行系统命令。
  Future<void>? _sequenceFuture;

  /// 合并安装完成、重新检测和手动继续产生的环境恢复请求。
  Future<void>? _environmentInitializationFuture;

  /// 本次进程是否已完成本机快照、更新及队列恢复。
  bool _runtimeInitialized = false;

  /// 全局后台协调器及差量轮询只挂载一次。
  bool _environmentSideEffectsStarted = false;

  /// 浏览模式升级为完整模式时不得重复记录一次启动访问。
  bool _startupVisitReported = false;

  /// 环境检测状态
  LinglongEnvCheckState _envCheckState = LinglongEnvCheckState.initial;

  /// 最近一次环境检测结果。
  ///
  /// 启动流程后续阶段（如埋点）依赖环境信息时，优先复用这里的结果，
  /// 避免 Provider 状态在重建/覆盖场景下暂时拿不到 result。
  LinglongEnvCheckResult? _lastEnvResult;

  /// 获取环境检测状态
  LinglongEnvCheckState get envCheckState => _envCheckState;

  /// 执行启动序列
  Future<void> runSequence() {
    if (_sequenceFuture case final pending?) {
      return pending;
    }
    if (state.isCompleted) {
      return Future<void>.value();
    }
    // 延迟至微任务启动，先保存共享 Future，防止检测状态同步发布导致重入。
    return _sequenceFuture = Future<void>.microtask(
      _runSequence,
    ).whenComplete(() => _sequenceFuture = null);
  }

  /// 启动网络体验，不把玲珑环境异常当作整个应用的启动失败。
  Future<void> _runSequence() async {
    AppLogger.info('Starting launch sequence...');

    try {
      // Step 1: 环境检测
      final envOk = await _checkEnvironment();

      final analyticsPreparation = _prepareStartupAnalyticsContext();
      var runtimeReady = false;
      if (envOk) {
        runtimeReady = await _initializeEnvironmentRuntime();
      } else {
        // 本机列表、CLI 搜索预热和队列恢复均延后，避免无环境时反复报错或执行旧任务。
        AppLogger.info('Environment unavailable, entering browse mode');
      }

      await analyticsPreparation;

      // 完成
      _complete(isBrowseOnly: !runtimeReady);
    } catch (e, s) {
      AppLogger.error('Launch sequence failed', e, s);
      _setError(e.toString());
    }
  }

  /// 仅在玲珑可用时后台预热候选索引，不阻塞首页显示。
  void _warmSearchIndex() {
    try {
      // 搜索候选索引不阻塞启动；有缓存时同步可用，无缓存时后台执行 ll-cli。
      ref.read(appSearchIndexProvider);
    } catch (e, stack) {
      AppLogger.warning('Failed to warm search index', e, stack);
    }
  }

  /// 环境检测
  ///
  /// 返回是否通过检测
  Future<bool> _checkEnvironment() async {
    state = state.copyWith(
      currentStep: LaunchStep.environmentCheck,
      stepInfo: const LaunchStepInfo(
        step: LaunchStep.environmentCheck,
        message: '正在检测环境...',
      ),
      progress: 0.0,
      clearError: true,
    );

    _envCheckState = LinglongEnvCheckState.checking;

    try {
      // 使用 LinglongEnvProvider 进行环境检测
      final envResult = await ref
          .read(linglongEnvProvider.notifier)
          .checkEnvironment();
      _lastEnvResult = envResult;

      // 更新状态
      _envCheckState = envResult.isOk
          ? LinglongEnvCheckState.success
          : LinglongEnvCheckState.failed;

      // 检测失败仍会采集架构与系统画像；浏览请求不能因此退回错误架构。
      await _fetchEnvironmentInfo();

      if (!envResult.isOk) {
        // 环境异常只影响本机能力，启动完成后再提醒，允许用户继续在线浏览。
        state = state.copyWith(
          progress: 1.0,
          stepInfo: LaunchStepInfo(
            step: LaunchStep.environmentCheck,
            message: envResult.errorMessage ?? '环境检测失败',
            error: envResult.errorDetail,
          ),
          clearError: true,
        );
        return false;
      }

      // 解析版本信息
      final versionOutput = envResult.llCliVersion ?? '未知版本';
      AppLogger.info('ll-cli version: $versionOutput');

      // 更新进度
      state = state.copyWith(
        progress: 0.5,
        stepInfo: LaunchStepInfo(
          step: LaunchStep.environmentCheck,
          message: '检测到 ll-cli: $versionOutput',
        ),
      );

      state = state.copyWith(progress: 1.0);
      AppLogger.info('Environment check completed');
      return true;
    } catch (e, stack) {
      _envCheckState = LinglongEnvCheckState.failed;
      AppLogger.warning(
        'Environment check failed, retaining browse access',
        e,
        stack,
      );
      state = state.copyWith(progress: 1.0, clearError: true);
      return false;
    }
  }

  /// 环境修复后补齐本机能力，不要求返回启动页或重启应用。
  ///
  /// 在用户处理环境问题后继续启动流程
  Future<void> continueAfterEnvCheck() async {
    // 启动未结束时等待同一轮编排，避免检测成功通知抢先重复恢复队列。
    if (_sequenceFuture case final pending?) {
      await pending;
    }
    if (_runtimeInitialized) return;
    if (_environmentInitializationFuture case final pending?) {
      return pending;
    }
    return _environmentInitializationFuture = Future<void>.microtask(
      _resumeEnvironmentInitialization,
    ).whenComplete(() => _environmentInitializationFuture = null);
  }

  /// 复用修复后的检测结果，以单次初始化恢复本机能力。
  Future<void> _resumeEnvironmentInitialization() async {
    try {
      final envResult = ref.read(linglongEnvProvider).result;
      if (!(envResult?.isOk ?? false)) {
        if (!await _checkEnvironment()) return;
      } else {
        _lastEnvResult = envResult;
        _envCheckState = LinglongEnvCheckState.success;
        await _fetchEnvironmentInfo();
      }
      if (await _initializeEnvironmentRuntime()) {
        _complete(isBrowseOnly: false);
      }
    } catch (e, s) {
      // 恢复失败不能重新锁住首页，用户仍能浏览并在下次操作时重试修复。
      AppLogger.error('Failed to restore Linglong capabilities', e, s);
    }
  }

  /// 所有依赖本机环境的启动阶段共用一个入口及已初始化标记。
  Future<bool> _initializeEnvironmentRuntime() async {
    if (_runtimeInitialized) return true;
    if (!ref.read(linglongEnvProvider).isReady) return false;
    _warmSearchIndex();
    await _initInstalledApps();
    // 用户可在后台初始化期间重新检测；每阶段读取缓存，失效后不继续执行系统操作。
    if (!ref.read(linglongEnvProvider).isReady) return false;
    await _checkUpdates();
    if (!ref.read(linglongEnvProvider).isReady) return false;
    await _recoverQueue();
    if (!ref.read(linglongEnvProvider).isReady) return false;
    _runtimeInitialized = true;
    return true;
  }

  /// 获取环境信息
  Future<void> _fetchEnvironmentInfo() async {
    try {
      final envResult = ref.read(linglongEnvProvider).result ?? _lastEnvResult;
      if (envResult == null) {
        return;
      }

      // 复用环境检测阶段已采集的数据，避免启动时重复执行系统命令。
      if (envResult.arch != null && envResult.arch!.isNotEmpty) {
        ref.read(globalAppProvider.notifier).setArch(envResult.arch!);
      }
      // 操作系统名称取发行版画像的 displayName（即 /etc/os-release 的
      // PRETTY_NAME，缺失时回落 NAME），供设置页关于卡片展示。
      if (envResult.distribution.displayName.isNotEmpty) {
        ref
            .read(globalAppProvider.notifier)
            .setOsName(envResult.distribution.displayName);
      }
      if (envResult.osVersion != null && envResult.osVersion!.isNotEmpty) {
        ref.read(globalAppProvider.notifier).setOsVersion(envResult.osVersion!);
      }
      if (envResult.llCliVersion != null &&
          envResult.llCliVersion!.isNotEmpty) {
        ref
            .read(globalAppProvider.notifier)
            .setLlVersion(envResult.llCliVersion!);
      }
    } catch (e) {
      AppLogger.warning('Failed to fetch environment info: $e');
    }
  }

  /// 预热启动上报上下文。
  ///
  /// 参考 Rust 版本：在启动完成前先准备匿名统计会话与商店版本信息，
  /// 确保真正发送启动访问记录时字段已经齐全。
  /// 用户体验计划关闭时不预热统计会话：不生成访问标识、不请求公网 IP；
  /// 商店版本解析与统计无关，仍照常执行。
  Future<void> _prepareStartupAnalyticsContext() async {
    try {
      final futures = <Future<Object?>>[_resolveAppVersion()];
      if (ref
          .read(globalAppProvider)
          .userPreferences
          .joinUserExperienceProgram) {
        futures.add(ref.read(analyticsRepositoryProvider).initializeSession());
      }
      await Future.wait<Object?>(futures);
    } catch (e) {
      AppLogger.warning('Failed to prepare startup analytics context: $e');
    }
  }

  /// 解析并缓存当前商店版本号。
  Future<void> _resolveAppVersion() async {
    try {
      final resolved = await ref.read(launchAppVersionResolverProvider)();
      final normalized = resolved.trim().isEmpty
          ? AppConfig.appVersion
          : resolved.trim();
      ref.read(globalAppProvider.notifier).setAppVersion(normalized);
    } catch (e) {
      ref.read(globalAppProvider.notifier).setAppVersion(AppConfig.appVersion);
      AppLogger.warning('Failed to resolve app version: $e');
    }
  }

  /// 初始化已安装应用
  Future<void> _initInstalledApps() async {
    state = state.copyWith(
      currentStep: LaunchStep.installedAppsInit,
      stepInfo: const LaunchStepInfo(
        step: LaunchStep.installedAppsInit,
        message: '正在加载已安装应用...',
      ),
      progress: 0.0,
    );

    try {
      // 刷新已安装应用列表
      await ref.read(installedAppsProvider.notifier).refresh();

      final apps = ref.read(installedAppsProvider).apps;
      state = state.copyWith(
        progress: 1.0,
        installedAppsCount: apps.length,
        stepInfo: LaunchStepInfo(
          step: LaunchStep.installedAppsInit,
          message: '已加载 ${apps.length} 个已安装应用',
        ),
      );

      AppLogger.info('Installed apps initialized: ${apps.length} apps');
    } catch (e) {
      AppLogger.warning('Failed to load installed apps: $e');
      // 不抛出异常，允许继续
      state = state.copyWith(progress: 1.0);
    }
  }

  /// 检查更新
  Future<void> _checkUpdates() async {
    state = state.copyWith(
      currentStep: LaunchStep.updateCheck,
      stepInfo: const LaunchStepInfo(
        step: LaunchStep.updateCheck,
        message: '正在检查更新...',
      ),
      progress: 0.0,
    );

    try {
      // 检查是否启用自动更新检查
      final autoCheck = ref
          .read(globalAppProvider)
          .userPreferences
          .autoCheckUpdate;
      if (!autoCheck) {
        state = state.copyWith(
          progress: 1.0,
          stepInfo: const LaunchStepInfo(
            step: LaunchStep.updateCheck,
            message: '已跳过更新检查',
          ),
        );
        return;
      }

      // 调用更新检查：从远程获取最新版本信息与已安装版本对比
      await ref.read(updateAppsProvider.notifier).checkUpdates();

      final updateCount = ref.read(updateAppsProvider).count;
      state = state.copyWith(
        progress: 1.0,
        stepInfo: LaunchStepInfo(
          step: LaunchStep.updateCheck,
          message: updateCount > 0 ? '发现 $updateCount 个可用更新' : '已是最新版本',
        ),
      );

      AppLogger.info('Update check completed: $updateCount updates found');
    } catch (e) {
      AppLogger.warning('Failed to check updates: $e');
      // 不抛出异常，允许继续
      state = state.copyWith(progress: 1.0);
    }
  }

  /// 恢复安装队列
  Future<void> _recoverQueue() async {
    state = state.copyWith(
      currentStep: LaunchStep.queueRecovery,
      stepInfo: const LaunchStepInfo(
        step: LaunchStep.queueRecovery,
        message: '正在恢复安装队列...',
      ),
      progress: 0.0,
    );

    try {
      final installQueue = ref.read(installQueueProvider.notifier);

      // 恢复必须使用完整本机实例和版本，更新任务不能只凭 appId 判断成功。
      final installedApps = ref.read(installedAppsProvider).apps;

      // 检查崩溃恢复
      await installQueue.checkRecovery(installedApps);

      // 获取待处理任务数量
      final pendingCount = ref.read(installQueueProvider).queue.length;

      state = state.copyWith(
        progress: 1.0,
        pendingTasksCount: pendingCount,
        stepInfo: LaunchStepInfo(
          step: LaunchStep.queueRecovery,
          message: pendingCount > 0 ? '发现 $pendingCount 个待安装任务' : '安装队列已就绪',
        ),
      );

      AppLogger.info('Queue recovery completed: $pendingCount pending tasks');
    } catch (e) {
      AppLogger.warning('Failed to recover queue: $e');
      // 不抛出异常，允许继续
      state = state.copyWith(progress: 1.0);
    }
  }

  /// 完成启动序列
  void _complete({required bool isBrowseOnly}) {
    state = state.copyWith(
      currentStep: LaunchStep.completed,
      isCompleted: true,
      isBrowseOnly: isBrowseOnly,
      clearError: true,
      progress: 1.0,
      stepInfo: const LaunchStepInfo(
        step: LaunchStep.completed,
        message: '启动完成',
      ),
    );

    AppLogger.info('Launch sequence completed');

    if (!isBrowseOnly) {
      _startEnvironmentSideEffects();
      // 环境故障期间自动出队已暂停；事实核验结束后再唤醒现有 pending 任务。
      if (ref.read(installQueueProvider).queue.isNotEmpty) {
        unawaited(ref.read(installQueueProvider.notifier).startProcessing());
      }
    }

    if (!_startupVisitReported) {
      _startupVisitReported = true;
      _reportStartupVisit();
    }

    // 修复结果可能在浏览上下文准备期间到达，完成后再补做，避免漏掉状态转换。
    if (isBrowseOnly && (ref.read(linglongEnvProvider).result?.isOk ?? false)) {
      unawaited(continueAfterEnvCheck());
    }
  }

  /// 只有本机初始化完成后才允许后台消费副作用及执行差量 CLI 轮询。
  void _startEnvironmentSideEffects() {
    // 后续环境故障恢复复用原协调器，唤醒之前暂停的 Outbox，避免重新注册监听。
    ref.read(appOperationLifecycleCoordinatorProvider).resumePendingEffects();
    if (_environmentSideEffectsStarted) return;
    _environmentSideEffectsStarted = true;

    // 本地任务、批次和 Outbox 恢复完成后再启动全局副作用协调器，
    // 避免系统通知或列表刷新抢在启动事实核验之前执行。
    // 启动已安装列表差量检测：首轮检测即旧版对齐的启动全量基线上报。
    // 放在统计上下文预热完成之后，确保上报时 visitorId/clientIp 已就绪。
    ref.read(installedAppDiffReportServiceProvider).start();
  }

  /// 上报启动访问记录（携带设备/环境信息）
  void _reportStartupVisit() {
    // 用户体验计划关闭时不发送任何统计上报。
    if (!ref
        .read(globalAppProvider)
        .userPreferences
        .joinUserExperienceProgram) {
      AppLogger.info('Launch visit report skipped: program disabled');
      return;
    }
    final globalApp = ref.read(globalAppProvider);
    final envResult = ref.read(linglongEnvProvider).result ?? _lastEnvResult;
    ref
        .read(analyticsRepositoryProvider)
        .reportVisit(
          arch: globalApp.arch,
          llVersion: globalApp.llVersion,
          llBinVersion: envResult?.llBinVersion,
          detailMsg: envResult?.detailMsg,
          osVersion: globalApp.osVersion,
          // 仓库配置不再允许用户切换，埋点统一记录默认仓库即可。
          repoName: AppConfig.defaultStoreRepoName,
          appVersion: globalApp.appVersion,
        );
  }

  /// 设置错误
  void _setError(String message) {
    state = state.copyWith(
      currentStep: LaunchStep.error,
      hasError: true,
      errorMessage: message,
      stepInfo: LaunchStepInfo(
        step: LaunchStep.error,
        message: '启动失败',
        error: message,
      ),
    );
  }

  /// 重试启动序列
  Future<void> retry() async {
    state = const LaunchState();
    await runSequence();
  }

  /// 跳过当前步骤（仅用于错误恢复）
  void skipCurrentStep() {
    if (!ref.read(linglongEnvProvider).isReady) {
      // 手动跳过只恢复浏览能力，不能让历史错误恢复入口绕过本机环境门禁。
      _complete(isBrowseOnly: true);
      return;
    }
    final nextSteps = {
      LaunchStep.environmentCheck: LaunchStep.installedAppsInit,
      LaunchStep.installedAppsInit: LaunchStep.updateCheck,
      LaunchStep.updateCheck: LaunchStep.queueRecovery,
      LaunchStep.queueRecovery: LaunchStep.completed,
      LaunchStep.error: LaunchStep.environmentCheck,
      LaunchStep.completed: LaunchStep.completed,
    };

    final nextStep = nextSteps[state.currentStep] ?? LaunchStep.completed;
    state = state.copyWith(
      currentStep: nextStep,
      hasError: false,
      clearError: true,
      progress: 0.0,
    );

    if (nextStep != LaunchStep.completed) {
      // 继续执行下一步
      _continueFromStep(nextStep);
    }
  }

  /// 从指定步骤继续
  Future<void> _continueFromStep(LaunchStep step) async {
    switch (step) {
      case LaunchStep.environmentCheck:
        await _checkEnvironment();
        break;
      case LaunchStep.installedAppsInit:
        await _initInstalledApps();
        break;
      case LaunchStep.updateCheck:
        await _checkUpdates();
        break;
      case LaunchStep.queueRecovery:
        await _recoverQueue();
        break;
      case LaunchStep.completed:
        _runtimeInitialized = true;
        _complete(isBrowseOnly: false);
        break;
      case LaunchStep.error:
        break;
    }

    if (state.currentStep != LaunchStep.completed &&
        state.currentStep != LaunchStep.error) {
      final nextSteps = {
        LaunchStep.environmentCheck: LaunchStep.installedAppsInit,
        LaunchStep.installedAppsInit: LaunchStep.updateCheck,
        LaunchStep.updateCheck: LaunchStep.queueRecovery,
        LaunchStep.queueRecovery: LaunchStep.completed,
      };

      final nextStep = nextSteps[state.currentStep];
      if (nextStep != null) {
        state = state.copyWith(currentStep: nextStep, progress: 0.0);
        await _continueFromStep(nextStep);
      }
    }
  }
}

/// 便捷访问 Provider

/// 是否启动完成
@riverpod
bool isLaunchCompleted(Ref ref) {
  return ref.watch(launchSequenceProvider).isCompleted;
}

/// 启动是否有错误
@riverpod
bool hasLaunchError(Ref ref) {
  return ref.watch(launchSequenceProvider).hasError;
}

/// 当前启动进度
@riverpod
double launchProgress(Ref ref) {
  return ref.watch(launchSequenceProvider).totalProgress;
}

/// 当前启动步骤
@riverpod
LaunchStep currentLaunchStep(Ref ref) {
  return ref.watch(launchSequenceProvider).currentStep;
}
