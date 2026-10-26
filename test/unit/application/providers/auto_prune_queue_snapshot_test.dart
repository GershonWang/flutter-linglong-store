/// 验证清理策略入队冻结，人工重试与旧快照兼容。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/auto_prune_preference_provider.dart';
import 'package:linglong_store/application/providers/install_queue_provider.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/domain/models/app_operation_journal_snapshot.dart';
import 'package:linglong_store/domain/models/install_progress.dart';
import 'package:linglong_store/domain/models/install_task.dart';

import '../../../helpers/memory_app_operation_journal_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppLogger.init);

  test('入队策略不随偏好改变，后续任务使用新策略', () async {
    SharedPreferences.setMockInitialValues({});
    var preserve = true;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        appOperationJournalRepositoryProvider.overrideWithValue(
          MemoryAppOperationJournalRepository(),
        ),
        noAutoPrunePreferenceProvider.overrideWith((ref) => preserve),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(installQueueProvider.notifier)
      ..pauseDequeueForSettings();
    queue.enqueueOperation(
      kind: InstallTaskKind.install,
      appId: 'org.first',
      appName: 'first',
    );
    preserve = false;
    container.invalidate(noAutoPrunePreferenceProvider);
    queue.enqueueOperation(
      kind: InstallTaskKind.install,
      appId: 'org.second',
      appName: 'second',
    );
    expect(
      container
          .read(installQueueProvider)
          .queue
          .map((task) => task.noAutoPrune),
      [true, false],
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('重试保留原策略而非读取当前偏好', () async {
    SharedPreferences.setMockInitialValues({});
    const failed = InstallTask(
      id: 'failed',
      appId: 'org.demo',
      appName: 'demo',
      noAutoPrune: true,
      status: InstallStatus.failed,
      createdAt: 1,
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        appOperationJournalRepositoryProvider.overrideWithValue(
          MemoryAppOperationJournalRepository(
            const AppOperationJournalSnapshot(history: [failed]),
          ),
        ),
        noAutoPrunePreferenceProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(installQueueProvider.notifier)
      ..pauseDequeueForSettings();
    queue.retryFailedTask('failed');
    expect(container.read(installQueueProvider).queue.single.noAutoPrune, true);
    await Future<void>.delayed(Duration.zero);
  });

  test('旧任务快照缺少清理字段时沿用默认行为', () {
    final task = InstallTask.fromJson({
      'id': 'old',
      'appId': 'org.demo',
      'appName': 'demo',
      'createdAt': 1,
    });
    expect(task.noAutoPrune, false);
    expect(
      InstallTask.fromJson(
        task.copyWith(noAutoPrune: true).toJson(),
      ).noAutoPrune,
      true,
    );
  });

  test('整批升级冻结一致策略，偏好改变不回写批次成员', () async {
    SharedPreferences.setMockInitialValues({});
    var preserve = true;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        appOperationJournalRepositoryProvider.overrideWithValue(
          MemoryAppOperationJournalRepository(),
        ),
        noAutoPrunePreferenceProvider.overrideWith((ref) => preserve),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(installQueueProvider.notifier)
      ..pauseDequeueForSettings();
    queue.enqueueBatchOperations(const [
      EnqueueTaskParams(
        kind: InstallTaskKind.update,
        appId: 'org.first',
        appName: 'first',
      ),
      EnqueueTaskParams(
        kind: InstallTaskKind.update,
        appId: 'org.second',
        appName: 'second',
      ),
    ]);
    preserve = false;
    container.invalidate(noAutoPrunePreferenceProvider);
    expect(
      container
          .read(installQueueProvider)
          .queue
          .map((task) => task.noAutoPrune),
      [true, true],
    );
    await Future<void>.delayed(Duration.zero);
  });
}
