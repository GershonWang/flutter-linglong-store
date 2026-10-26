/// 环境缺失下的能力边界回归测试，避免继续浏览被误作操作授权。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/install_queue_provider.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/launch_provider.dart';
import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/application/services/linglong_environment_service.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/core/platform/shell_command_executor.dart';
import 'package:linglong_store/domain/models/install_progress.dart';
import 'package:linglong_store/domain/models/install_queue_state.dart';
import 'package:linglong_store/domain/models/install_task.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/models/app_operation_journal_snapshot.dart';
import '../../../helpers/memory_app_operation_journal_repository.dart';

const _missing = LinglongEnvCheckResult(isOk: false, checkedAt: 1);
const _ready = LinglongEnvCheckResult(isOk: true, checkedAt: 2);

void main() {
  setUpAll(AppLogger.init);

  test('继续浏览不授予安装能力', () {
    const state = LinglongEnvState(result: _missing, wasSkipped: true);
    expect(state.canContinue, isTrue);
    expect(state.isReady, isFalse);
    expect(state.isUnavailable, isTrue);
    expect(const LinglongEnvState().isUnavailable, isFalse);
  });

  test('并发检测合并，重新检测期间保留已知故障', () async {
    final service = _DeferredEnvironmentService();
    final container = ProviderContainer(
      overrides: [
        linglongEnvironmentServiceProvider.overrideWithValue(service),
        linglongEnvProvider.overrideWith(_MissingEnvironment.new),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(linglongEnvProvider.notifier);
    final first = notifier.checkEnvironment();
    final second = notifier.recheck();
    expect(service.calls, 1);
    expect(container.read(linglongEnvProvider).isChecking, isTrue);
    expect(container.read(linglongEnvProvider).isUnavailable, isTrue);
    service.result.complete(_ready);
    expect(await first, _ready);
    expect(await second, _ready);
    expect(container.read(linglongEnvProvider).isReady, isTrue);
  });

  test('缺环境时拒绝单个和批量入队，不改变恢复任务或历史', () async {
    final container = ProviderContainer(
      overrides: [
        linglongEnvProvider.overrideWith(_MissingEnvironment.new),
        installQueueProvider.overrideWith(_PersistedQueue.new),
      ],
    );
    addTearDown(container.dispose);
    final before = container.read(installQueueProvider);
    final notifier = container.read(installQueueProvider.notifier);
    expect(notifier.enqueueInstall(appId: 'new.app', appName: 'New'), isEmpty);
    expect(
      notifier.enqueueBatchOperations([
        const EnqueueTaskParams(
          kind: InstallTaskKind.update,
          appId: 'new.app',
          appName: 'New',
        ),
      ]),
      isEmpty,
    );
    notifier.retryFailedTask('failed');
    await notifier.startProcessing();
    await notifier.checkRecovery(const []);
    expect(container.read(installQueueProvider), same(before));
  });

  test('环境检测通过但本机恢复未完成时不允许新任务抢先执行', () {
    final container = ProviderContainer(
      overrides: [
        linglongEnvProvider.overrideWith(_ReadyEnvironment.new),
        launchSequenceProvider.overrideWith(_RestoringLaunch.new),
        installQueueProvider.overrideWith(_PersistedQueue.new),
      ],
    );
    addTearDown(container.dispose);
    final before = container.read(installQueueProvider);
    expect(
      container
          .read(installQueueProvider.notifier)
          .enqueueInstall(appId: 'new.app', appName: 'New'),
      isEmpty,
    );
    expect(container.read(installQueueProvider), same(before));
  });

  test('落盘等待期间环境失效，未执行任务退回等待且不记为失败', () async {
    final journal = _GateJournal();
    final container = ProviderContainer(
      overrides: [
        linglongEnvProvider.overrideWith(_ReadyEnvironment.new),
        installQueueProvider.overrideWith(_WaitingQueue.new),
        appOperationJournalRepositoryProvider.overrideWithValue(journal),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(installQueueProvider.notifier);
    final task = container.read(installQueueProvider).queue.single;
    final processing = notifier.processInstallTask(task);
    await journal.entered.future;
    container.read(linglongEnvProvider.notifier).skipCheck();
    (container.read(linglongEnvProvider.notifier) as _ReadyEnvironment)
        .loseEnvironment();
    journal.release.complete();
    await processing;
    final after = container.read(installQueueProvider);
    expect(after.currentTask, isNull);
    expect(after.isProcessing, isFalse);
    expect(after.queue.single, task);
    expect(after.history, isEmpty);
  });
}

/// 正常结果可在磁盘屏障等待期间变为故障，模拟用户重新检测。
class _ReadyEnvironment extends LinglongEnv {
  @override
  LinglongEnvState build() => const LinglongEnvState(result: _ready);

  void loseEnvironment() => state = const LinglongEnvState(result: _missing);
}

/// 环境结果刚修复，但启动编排尚未完成本机快照与队列核验。
class _RestoringLaunch extends LaunchSequence {
  @override
  LaunchState build() =>
      const LaunchState(isCompleted: true, isBrowseOnly: true);
}

/// 使用真实出队逻辑，只有等待任务，没有真实运行中的传输。
class _WaitingQueue extends InstallQueue {
  @override
  InstallQueueState build() => const InstallQueueState(
    queue: [
      InstallTask(
        id: 'pending',
        appId: 'pending.app',
        appName: 'Pending',
        createdAt: 1,
      ),
    ],
  );
}

/// 控制真实 Journal 落盘屏障，验证故障发生在异步等待期间的任务语义。
class _GateJournal extends MemoryAppOperationJournalRepository {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> save(AppOperationJournalSnapshot snapshot) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.save(snapshot);
  }
}

/// 缓存明确的缺失结果，验证跳过启动检查不会改变能力事实。
class _MissingEnvironment extends LinglongEnv {
  @override
  LinglongEnvState build() =>
      const LinglongEnvState(result: _missing, wasSkipped: true);
}

/// 保留恢复中的任务和历史，不构造真实日志存储或 CLI 仓库。
class _PersistedQueue extends InstallQueue {
  @override
  InstallQueueState build() => const InstallQueueState(
    queue: [
      InstallTask(
        id: 'pending',
        appId: 'pending.app',
        appName: 'Pending',
        createdAt: 1,
      ),
    ],
    currentTask: InstallTask(
      id: 'recovering',
      appId: 'recovering.app',
      appName: 'Recovery',
      status: InstallStatus.installing,
      createdAt: 1,
    ),
    history: [
      InstallTask(
        id: 'failed',
        appId: 'failed.app',
        appName: 'Failed',
        status: InstallStatus.failed,
        createdAt: 1,
      ),
    ],
  );
}

/// 延迟完成探测以覆盖重复点击和检测中状态的真实交错。
class _DeferredEnvironmentService extends LinglongEnvironmentService {
  _DeferredEnvironmentService() : super(executor: ShellCommandExecutor());

  final result = Completer<LinglongEnvCheckResult>();
  int calls = 0;

  @override
  Future<LinglongEnvCheckResult> checkEnvironment() {
    calls++;
    return result.future;
  }
}
