import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/api_exceptions.dart';
import '../../domain/models/installed_app.dart';
import '../../domain/models/running_app.dart';
import '../../domain/repositories/app_repository.dart';
import 'application_dependency_providers.dart';
import 'linglong_env_provider.dart';

part 'running_process_provider.g.dart';

/// Rust 版本的失败退避表：1 次失败 3s，2 次失败 6s，3 次及以上 10s。
const _refreshBackoffTable = <Duration>[
  Duration(seconds: 3),
  Duration(seconds: 6),
  Duration(seconds: 10),
];

@visibleForTesting
Future<List<RunningApp>> enrichRunningAppsWithDetails({
  required AppRepository appRepository,
  required List<RunningApp> apps,
}) async {
  if (apps.isEmpty) {
    return const [];
  }

  final installedLikeApps = apps
      .map(
        (app) => InstalledApp(
          appId: app.appId,
          name: app.name,
          version: app.version,
          arch: app.arch,
          channel: app.channel,
          icon: app.icon,
        ),
      )
      .toList();

  final enrichedApps = await appRepository.enrichInstalledAppsWithDetails(
    installedLikeApps,
  );
  final enrichedByAppId = {for (final app in enrichedApps) app.appId: app};

  return apps.map((app) {
    final enriched = enrichedByAppId[app.appId];
    if (enriched == null) {
      return app;
    }

    return app.copyWith(
      name: enriched.name.isNotEmpty ? enriched.name : app.name,
      icon: enriched.icon ?? app.icon,
    );
  }).toList();
}

/// 运行中进程状态
class RunningProcessState {
  const RunningProcessState({
    this.apps = const [],
    this.isInitialLoading = false,
    this.isRefreshing = false,
    this.error,
    this.lastRefreshedAt,
    this.killLoadingIds = const <String>{},
  });

  /// 运行中应用列表
  final List<RunningApp> apps;

  /// 首次加载中
  final bool isInitialLoading;

  /// 静默刷新中
  final bool isRefreshing;

  /// 最近一次错误
  final String? error;

  /// 最近一次成功刷新时间
  final DateTime? lastRefreshedAt;

  /// 正在执行停止操作的行 id 集合
  final Set<String> killLoadingIds;

  bool get hasData => apps.isNotEmpty;

  /// 复制并更新
  RunningProcessState copyWith({
    List<RunningApp>? apps,
    bool? isInitialLoading,
    bool? isRefreshing,
    String? error,
    bool clearError = false,
    DateTime? lastRefreshedAt,
    Set<String>? killLoadingIds,
  }) {
    return RunningProcessState(
      apps: apps ?? this.apps,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      error: clearError ? null : (error ?? this.error),
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      killLoadingIds: killLoadingIds ?? this.killLoadingIds,
    );
  }
}

/// 运行中进程 Provider
///
/// 对齐 Rust 版本的行为：
/// - 仅在“玲珑进程”标签激活且页面可见时轮询
/// - 并发保护
/// - 失败退避
/// - 恢复可见时立即补刷新
/// - 行级停止 loading
@Riverpod(keepAlive: true)
class RunningProcess extends _$RunningProcess {
  Timer? _refreshTimer;
  bool _isFetching = false;
  int _failureCount = 0;
  bool _isProcessTabActive = false;
  bool _isPageVisible = true;

  /// 环境切换时作废旧进程快照，避免恢复后旧请求覆盖新环境状态。
  int _latestRequestId = 0;

  /// 默认刷新间隔（3 秒）
  static const Duration defaultRefreshInterval = Duration(seconds: 3);

  @override
  RunningProcessState build() {
    ref.onDispose(() {
      _refreshTimer?.cancel();
    });

    // 仅订阅可用性边界，安装进度不会重建进程列表或触发额外轮询。
    ref.listen(linglongEnvProvider.select((env) => env.isUnavailable), (
      previous,
      unavailable,
    ) {
      if (unavailable) {
        _latestRequestId++;
        _failureCount = 0;
        _cancelTimer();
        state = const RunningProcessState();
      } else if (previous == true) {
        _syncPolling(immediateRefresh: true);
      }
    });

    return const RunningProcessState();
  }

  /// 无环境时保留 Tab/可见性意图，但暂停所有自动 CLI 请求。
  bool get _shouldPoll =>
      ref.mounted &&
      _isProcessTabActive &&
      _isPageVisible &&
      !ref.read(linglongEnvProvider).isUnavailable;

  /// 当前是否正在自动刷新
  bool get isAutoRefreshing => _refreshTimer != null;

  /// 提供当前运行中应用快照，供卸载等同步流程安全读取。
  List<RunningApp> get currentApps => state.apps;

  /// 当前是否处于进程 Tab。
  void setProcessTabActive(bool isActive) {
    _isProcessTabActive = isActive;
    _syncPolling(immediateRefresh: isActive);
  }

  /// 当前页面可见性变化。
  void setPageVisible(bool isVisible) {
    _isPageVisible = isVisible;
    _syncPolling(immediateRefresh: isVisible);
  }

  /// 手动刷新运行中进程列表。
  Future<void> refresh() async {
    _cancelTimer();
    await _fetchOnce(silent: state.hasData);
    _scheduleNext();
  }

  Future<void> _fetchOnce({required bool silent}) async {
    if (_isFetching || ref.read(linglongEnvProvider).isUnavailable) {
      return;
    }

    final requestId = ++_latestRequestId;
    _isFetching = true;
    final hasData = state.hasData;

    state = state.copyWith(
      isInitialLoading: !silent && !hasData,
      isRefreshing: silent || hasData,
      clearError: true,
    );

    try {
      final repo = ref.read(linglongCliRepositoryProvider);
      final rawApps = await repo.getRunningApps();
      // 缺环境时停止详情富化，同时防止晚到的 CLI 响应重新填回本机数据。
      if (!_canApplyRequest(requestId)) {
        return;
      }
      final appRepository = ref.read(appRepositoryProvider);
      final apps = await enrichRunningAppsWithDetails(
        appRepository: appRepository,
        apps: rawApps,
      );

      if (!_canApplyRequest(requestId)) {
        return;
      }

      _failureCount = 0;
      state = state.copyWith(
        apps: apps,
        isInitialLoading: false,
        isRefreshing: false,
        clearError: true,
        lastRefreshedAt: DateTime.now(),
      );
    } catch (e) {
      if (!_canApplyRequest(requestId)) {
        return;
      }
      _failureCount += 1;
      state = state.copyWith(
        isInitialLoading: false,
        isRefreshing: false,
        error: presentAppError(e),
      );
    } finally {
      _isFetching = false;
    }
  }

  /// 只接收当前环境下尚未被作废的进程查询结果。
  bool _canApplyRequest(int requestId) =>
      ref.mounted &&
      requestId == _latestRequestId &&
      !ref.read(linglongEnvProvider).isUnavailable;

  void _syncPolling({required bool immediateRefresh}) {
    if (!_shouldPoll) {
      _cancelTimer();
      return;
    }

    _cancelTimer();

    if (immediateRefresh) {
      unawaited(_fetchOnce(silent: state.hasData).whenComplete(_scheduleNext));
      return;
    }

    _scheduleNext();
  }

  void _scheduleNext() {
    _cancelTimer();
    if (!_shouldPoll) {
      return;
    }

    final interval = _failureCount > 0
        ? _refreshBackoffTable[(_failureCount - 1).clamp(
            0,
            _refreshBackoffTable.length - 1,
          )]
        : defaultRefreshInterval;

    _refreshTimer = Timer(interval, () async {
      if (!_shouldPoll) {
        _scheduleNext();
        return;
      }

      await _fetchOnce(silent: true);
      _scheduleNext();
    });
  }

  void _cancelTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  /// 停止指定应用。
  Future<bool> killApp(RunningApp app) async {
    // 即使调用方持有旧行快照，也不能在已确认缺环境后继续执行停止命令。
    if (ref.read(linglongEnvProvider).isUnavailable) {
      return false;
    }
    final nextLoadingIds = Set<String>.from(state.killLoadingIds)..add(app.id);
    state = state.copyWith(killLoadingIds: nextLoadingIds);

    try {
      final repo = ref.read(linglongCliRepositoryProvider);
      await repo.killApp(app.appId);
      await _fetchOnce(silent: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      final updatedIds = Set<String>.from(state.killLoadingIds)..remove(app.id);
      state = state.copyWith(killLoadingIds: updatedIds);
      _scheduleNext();
    }
  }
}

/// 运行中应用列表
@riverpod
List<RunningApp> runningAppsList(Ref ref) {
  return ref.watch(runningProcessProvider).apps;
}

/// 运行中应用数量
@riverpod
int runningAppsCount(Ref ref) {
  return ref.watch(runningProcessProvider).apps.length;
}
