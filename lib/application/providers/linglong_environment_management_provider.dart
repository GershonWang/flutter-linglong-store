import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../domain/models/install_queue_state.dart';
import '../../domain/models/linglong_env_check_result.dart';
import '../../domain/models/linglong_environment_management.dart';
import '../../domain/models/linglong_repository_config.dart';
import '../services/linglong_environment_management_service.dart';
import 'application_dependency_providers.dart';
import 'install_queue_provider.dart';
import 'linglong_env_provider.dart';
import 'linglong_cli_capabilities_provider.dart';
import 'linglong_app_analysis_provider.dart';

/// 镜像写入已提交但无法确认结果，调用方必须展示未确认反馈而非成功通知。
class LinglongMirrorConfirmationException implements Exception {
  /// 保存完整回读诊断，供界面复制和用户排查。
  const LinglongMirrorConfirmationException(this.diagnostic);

  /// 回读失败或配置不符的真实原因。
  final String diagnostic;

  /// 不叠加业务提示；界面通过国际化文案解释未确认状态。
  @override
  String toString() => diagnostic;
}

enum LinglongEnvironmentManagementStatus {
  idle,
  loading,
  ready,
  applying,
  failed,
}

class LinglongEnvironmentManagementState {
  const LinglongEnvironmentManagementState({
    this.status = LinglongEnvironmentManagementStatus.idle,
    this.analysis,
    this.repositoryConfig,
    this.activeAction,
    this.repairResult,
    this.errorMessage,
    this.unconfirmedMirrorAlias,
  });

  final LinglongEnvironmentManagementStatus status;
  final LinglongEnvironmentAnalysis? analysis;
  final LinglongRepositoryConfig? repositoryConfig;
  final LinglongEnvironmentRepairAction? activeAction;
  final LinglongEnvironmentRepairResult? repairResult;
  final String? errorMessage;

  /// 最近一次已提交但未回读确认的仓库；非空时整个旧配置快照均视为未知。
  final String? unconfirmedMirrorAlias;

  bool get isBusy =>
      status == LinglongEnvironmentManagementStatus.loading ||
      status == LinglongEnvironmentManagementStatus.applying;

  LinglongEnvironmentManagementState copyWith({
    LinglongEnvironmentManagementStatus? status,
    LinglongEnvironmentAnalysis? analysis,
    LinglongRepositoryConfig? repositoryConfig,
    LinglongEnvironmentRepairAction? activeAction,
    LinglongEnvironmentRepairResult? repairResult,
    String? errorMessage,
    bool clearActiveAction = false,
    bool clearError = false,
    bool clearRepairResult = false,
    String? unconfirmedMirrorAlias,
    bool clearUnconfirmedMirror = false,
  }) {
    return LinglongEnvironmentManagementState(
      status: status ?? this.status,
      analysis: analysis ?? this.analysis,
      repositoryConfig: repositoryConfig ?? this.repositoryConfig,
      activeAction: clearActiveAction
          ? null
          : (activeAction ?? this.activeAction),
      repairResult: clearRepairResult
          ? null
          : (repairResult ?? this.repairResult),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      unconfirmedMirrorAlias: clearUnconfirmedMirror
          ? null
          : (unconfirmedMirrorAlias ?? this.unconfirmedMirrorAlias),
    );
  }
}

final linglongEnvironmentManagementServiceProvider =
    Provider<LinglongEnvironmentManagementService>((ref) {
      return LinglongEnvironmentManagementService(
        executor: ref.watch(shellCommandExecutorProvider),
        environmentService: ref.watch(linglongEnvironmentServiceProvider),
      );
    });

final linglongEnvironmentManagementProvider =
    NotifierProvider<
      LinglongEnvironmentManagement,
      LinglongEnvironmentManagementState
    >(
      LinglongEnvironmentManagement.new,
      name: 'linglongEnvironmentManagementProvider',
    );

class LinglongEnvironmentManagement
    extends Notifier<LinglongEnvironmentManagementState> {
  @override
  LinglongEnvironmentManagementState build() {
    return const LinglongEnvironmentManagementState();
  }

  Future<void> load() async {
    state = state.copyWith(
      status: LinglongEnvironmentManagementStatus.loading,
      clearError: true,
    );

    try {
      final analysis = await ref
          .read(linglongEnvironmentManagementServiceProvider)
          .analyzeEnvironment();
      final repositoryConfig = await ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .getRepositoryConfig();

      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.ready,
        analysis: analysis,
        repositoryConfig: repositoryConfig,
        clearUnconfirmedMirror: true,
        clearActiveAction: true,
        clearError: true,
      );
    } catch (error, stackTrace) {
      AppLogger.error('[LinglongEnvManagement] 加载环境管理状态失败', error, stackTrace);
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        errorMessage: _formatError(error),
        clearActiveAction: true,
      );
    }
  }

  Future<void> refreshRepositoryConfig() async {
    try {
      final repositoryConfig = await ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .getRepositoryConfig();
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.ready,
        repositoryConfig: repositoryConfig,
        clearUnconfirmedMirror: true,
        clearActiveAction: true,
        clearError: true,
      );
    } catch (error, stackTrace) {
      AppLogger.error('[LinglongEnvManagement] 刷新仓库配置失败', error, stackTrace);
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        errorMessage: _formatError(error),
        clearActiveAction: true,
      );
    }
  }

  Future<LinglongEnvironmentRepairResult> repairOstreeRepository() {
    return _runRepairAction(
      LinglongEnvironmentRepairAction.ostreeFsckDelete,
      () => ref
          .read(linglongEnvironmentManagementServiceProvider)
          .repairOstreeRepository(),
    );
  }

  /// 修复玲珑数据目录权限。
  ///
  /// 入口放在统一管理 Provider 中，确保 UI 不直接执行 `pkexec` 脚本，并复用修复后的重新分析流程。
  Future<LinglongEnvironmentRepairResult> repairLinglongDataPermissions() {
    return _runRepairAction(
      LinglongEnvironmentRepairAction.fixDataPermissions,
      () => ref
          .read(linglongEnvironmentManagementServiceProvider)
          .repairLinglongDataPermissions(),
    );
  }

  Future<LinglongEnvironmentRepairResult> moveLinglongStorage(
    String targetPath,
  ) async {
    final blockedResult = _buildStorageMoveBlockedResult(
      ref.read(installQueueProvider),
    );
    if (blockedResult != null) {
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        activeAction: LinglongEnvironmentRepairAction.moveStorageRoot,
        repairResult: blockedResult,
        clearError: true,
      );
      return blockedResult;
    }

    return _runRepairAction(
      LinglongEnvironmentRepairAction.moveStorageRoot,
      () => ref
          .read(linglongEnvironmentManagementServiceProvider)
          .moveLinglongStorage(targetPath),
    );
  }

  LinglongEnvironmentRepairResult? _buildStorageMoveBlockedResult(
    InstallQueueState installQueue,
  ) {
    if (!installQueue.hasActiveTasks()) return null;

    final currentTask = installQueue.currentTask;
    final activeName = currentTask == null
        ? null
        : (currentTask.appName.isNotEmpty
              ? currentTask.appName
              : currentTask.appId);
    // 保存位置迁移会整体操作 /var/lib/linglong，必须避免与 ll-cli 安装队列并发。
    return LinglongEnvironmentRepairResult(
      action: LinglongEnvironmentRepairAction.moveStorageRoot,
      success: false,
      code: activeName == null
          ? LinglongEnvironmentRepairResultCode.storageMoveBlockedByActiveTask
          : LinglongEnvironmentRepairResultCode
                .storageMoveBlockedByNamedActiveTask,
      subject: activeName,
    );
  }

  Future<String> addRepository({
    required String name,
    required String url,
    String? alias,
  }) {
    return _runRepositoryMutation(
      () => ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .addRepository(name: name, url: url, alias: alias),
    );
  }

  Future<String> updateRepository({
    required String aliasOrName,
    required String url,
  }) {
    return _runRepositoryMutation(
      () => ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .updateRepository(aliasOrName: aliasOrName, url: url),
    );
  }

  Future<String> removeRepository(String aliasOrName) {
    return _runRepositoryMutation(
      () => ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .removeRepository(aliasOrName),
    );
  }

  Future<String> setDefaultRepository(String aliasOrName) {
    return _runRepositoryMutation(
      () => ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .setDefaultRepository(aliasOrName),
    );
  }

  Future<String> setRepositoryPriority(String aliasOrName, int priority) {
    return _runRepositoryMutation(
      () => ref
          .read(linglongRepositoryManagementRepositoryProvider)
          .setRepositoryPriority(aliasOrName, priority),
    );
  }

  /// 提交镜像配置后严格回读；低版只发送既有开关命令。
  Future<String> setRepositoryMirror(
    String aliasOrName, {
    required bool enabled,
    String? region,
  }) async {
    if (state.isBusy) throw StateError('Repository operation already running');
    final supportsRegion = ref
        .read(linglongCliCapabilitiesProvider)
        .supportsMirrorRegion;
    final requestedRegion = enabled && supportsRegion ? region : null;
    if (requestedRegion != null &&
        !LinglongRepoInfo.isSafeMirrorRegion(requestedRegion)) {
      throw ArgumentError.value(
        requestedRegion,
        'region',
        'Unsafe mirror region code',
      );
    }
    final repository = ref.read(linglongRepositoryManagementRepositoryProvider);
    state = state.copyWith(
      status: LinglongEnvironmentManagementStatus.applying,
      clearError: true,
    );
    String output;
    try {
      output = await repository.setRepositoryMirror(
        aliasOrName,
        enabled: enabled,
        region: requestedRegion,
      );
    } catch (error) {
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        errorMessage: _formatError(error),
      );
      rethrow;
    }

    try {
      final config = await repository.getRepositoryConfig();
      final matching = config.repos.where(
        (repo) => (repo.alias ?? repo.name) == aliasOrName,
      );
      final repo = matching.length == 1 ? matching.single : null;
      if (repo == null ||
          repo.isMirrorEnabled != enabled ||
          (enabled &&
              supportsRegion &&
              (repo.region ?? '') != (requestedRegion ?? ''))) {
        throw StateError(
          'Mirror configuration readback did not match requested state',
        );
      }
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.ready,
        repositoryConfig: config,
        clearError: true,
        clearUnconfirmedMirror: true,
      );
      return output;
    } catch (error, stackTrace) {
      AppLogger.error('[LinglongEnvManagement] 镜像配置已提交但未确认', error, stackTrace);
      final diagnostic = _formatError(error);
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        unconfirmedMirrorAlias: aliasOrName,
        errorMessage: diagnostic,
      );
      throw LinglongMirrorConfirmationException(diagnostic);
    }
  }

  Future<LinglongEnvironmentRepairResult> _runRepairAction(
    LinglongEnvironmentRepairAction action,
    Future<LinglongEnvironmentRepairResult> Function() operation,
  ) async {
    state = state.copyWith(
      status: LinglongEnvironmentManagementStatus.applying,
      activeAction: action,
      clearError: true,
      clearRepairResult: true,
    );

    try {
      final result = await operation();
      // 修复和迁移可能改变 inode 与仓库占用；失效只读缓存不会触发隐藏页扫描。
      if (result.success) invalidateLinglongAppAnalysis(ref);
      state = state.copyWith(repairResult: result);
      await load();
      state = state.copyWith(repairResult: result);
      return result;
    } catch (error, stackTrace) {
      AppLogger.error(
        '[LinglongEnvManagement] 修复动作执行失败: $action',
        error,
        stackTrace,
      );
      final result = LinglongEnvironmentRepairResult(
        action: action,
        success: false,
        code: LinglongEnvironmentRepairResultCode.unexpectedFailure,
        diagnostic: _formatError(error),
      );
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        activeAction: action,
        repairResult: result,
        errorMessage: result.diagnostic,
      );
      return result;
    }
  }

  Future<String> _runRepositoryMutation(
    Future<String> Function() operation,
  ) async {
    state = state.copyWith(
      status: LinglongEnvironmentManagementStatus.applying,
      clearError: true,
    );

    try {
      final output = await operation();
      await refreshRepositoryConfig();
      return output;
    } catch (error, stackTrace) {
      AppLogger.error('[LinglongEnvManagement] 仓库配置变更失败', error, stackTrace);
      state = state.copyWith(
        status: LinglongEnvironmentManagementStatus.failed,
        errorMessage: _formatError(error),
        clearActiveAction: true,
      );
      rethrow;
    }
  }

  String _formatError(Object error) {
    if (error is Exception) {
      return error.toString().replaceFirst('Exception: ', '');
    }
    return error.toString();
  }
}
