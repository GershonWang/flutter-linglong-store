import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/og_install_controller.dart';
import 'package:linglong_store/application/providers/app_operation_queue_provider.dart';
import 'package:linglong_store/application/providers/launch_provider.dart';
import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/domain/models/app_detail.dart';
import 'package:linglong_store/domain/models/install_task.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/repositories/app_repository.dart';

void main() {
  setUpAll(() async {
    await AppLogger.init();
  });

  group('OgInstallController', () {
    test('keeps request pending until launch sequence completes', () async {
      final harness = _OgInstallHarness(launchCompleted: false);

      harness.controller.acceptRawUrl('og://org.example.App');
      await harness.controller.processPending();

      expect(harness.detailRequests, isEmpty);
      expect(harness.enqueuedParams, isEmpty);

      harness.launchCompleted = true;
      await harness.controller.processPending();

      expect(harness.detailRequests, ['org.example.App']);
      expect(harness.enqueuedParams, hasLength(1));
      expect(harness.enqueuedParams.single.kind, InstallTaskKind.install);
      expect(harness.enqueuedParams.single.appId, 'org.example.App');
      expect(harness.enqueuedParams.single.appName, 'Example App');
    });

    test(
      'rejects invalid og url without touching repository or queue',
      () async {
        final harness = _OgInstallHarness();

        harness.controller.acceptRawUrl('https://example.com/app');
        await harness.controller.processPending();

        expect(harness.detailRequests, isEmpty);
        expect(harness.enqueuedParams, isEmpty);
        expect(harness.events.single.type, OgInstallEventType.invalid);
      },
    );

    test('blocks install when linglong environment is unavailable', () async {
      final harness = _OgInstallHarness(linglongEnvOk: false);

      harness.controller.acceptRawUrl('og://org.example.App');
      await harness.controller.processPending();

      expect(harness.detailRequests, isEmpty);
      expect(harness.enqueuedParams, isEmpty);
      expect(
        harness.events.map((event) => event.type),
        contains(OgInstallEventType.environmentUnavailable),
      );
    });

    test('emits duplicate event when queue refuses same app', () async {
      final harness = _OgInstallHarness(enqueueTaskId: '');

      harness.controller.acceptRawUrl('og://org.example.App');
      await harness.controller.processPending();

      expect(harness.detailRequests, ['org.example.App']);
      expect(harness.enqueuedParams, hasLength(1));
      expect(harness.events.last.type, OgInstallEventType.duplicate);
    });

    test('emits failure event when app detail cannot be loaded', () async {
      final harness = _OgInstallHarness(
        loadDetail: (_) async => throw Exception('network failed'),
      );

      harness.controller.acceptRawUrl('og://org.example.App');
      await harness.controller.processPending();

      expect(harness.enqueuedParams, isEmpty);
      expect(harness.events.last.type, OgInstallEventType.detailFailed);
      expect(harness.events.last.error, contains('network failed'));
    });
  });

  test('环境恢复期间保留协议请求，本机核验完成后只入队一次', () async {
    final repository = _RecordingAppRepository();
    final queue = _RecordingOperationQueue();
    final container = ProviderContainer(
      overrides: [
        launchSequenceProvider.overrideWith(_RecoveringLaunch.new),
        linglongEnvProvider.overrideWith(_RecoveringEnvironment.new),
        appRepositoryProvider.overrideWithValue(repository),
        appOperationQueueControllerProvider.overrideWithValue(queue),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(ogInstallControllerProvider);
    final events = <OgInstallEvent>[];
    final subscription = controller.events.listen(events.add);
    addTearDown(subscription.cancel);

    controller.acceptRawUrl('og://org.example.pending');
    await controller.processPending();
    await Future<void>.delayed(Duration.zero);
    expect(
      events.map((event) => event.type),
      contains(OgInstallEventType.environmentUnavailable),
    );
    expect(repository.requests, isEmpty);

    final environment =
        container.read(linglongEnvProvider.notifier) as _RecoveringEnvironment;
    environment.markAvailable();
    controller.acceptRawUrl('og://org.example.new');
    await controller.processPending();
    expect(repository.requests, isEmpty);
    expect(queue.requests, isEmpty);

    final launch =
        container.read(launchSequenceProvider.notifier) as _RecoveringLaunch;
    launch.completeRecovery();
    await Future<void>.delayed(Duration.zero);
    await controller.processPending();

    expect(repository.requests, <String>[
      'org.example.pending',
      'org.example.new',
    ]);
    expect(queue.requests, repository.requests);
  });
}

/// 可控的浏览启动状态，隔离真实平台初始化与本机队列核验。
class _RecoveringLaunch extends LaunchSequence {
  @override
  LaunchState build() =>
      const LaunchState(isCompleted: true, isBrowseOnly: true);

  /// 模拟运行环境恢复和本机初始化已经完成。
  void completeRecovery() {
    state = state.copyWith(isBrowseOnly: false);
  }
}

/// 已完成检测的环境快照，恢复过程中不执行任何真实 CLI 命令。
class _RecoveringEnvironment extends LinglongEnv {
  @override
  LinglongEnvState build() => const LinglongEnvState(
    checkState: LinglongEnvCheckState.success,
    result: LinglongEnvCheckResult(isOk: false, checkedAt: 1),
  );

  /// 模拟环境安装成功，而本机初始化尚未完成。
  void markAvailable() {
    state = state.copyWith(
      result: const LinglongEnvCheckResult(isOk: true, checkedAt: 2),
    );
  }
}

/// 记录协议请求触发的远端详情查询。
class _RecordingAppRepository extends Fake implements AppRepository {
  /// 按请求顺序记录协议详情，验证恢复期间没有提前加载。
  final List<String> requests = <String>[];

  @override
  Future<AppDetail> getAppDetail(
    String appId, {
    String? arch,
    String? repoName,
    String? module,
  }) async {
    requests.add(appId);
    return AppDetail(appId: appId, name: appId, version: '1.0.0');
  }
}

/// 记录协议入队，不执行真实的本机操作。
class _RecordingOperationQueue extends Fake
    implements AppOperationQueueController {
  /// 在运行环境核验后按 FIFO 写入的协议安装目标。
  final List<String> requests = <String>[];

  @override
  String enqueueAppOperation(EnqueueAppOperationParams params) {
    requests.add(params.appId);
    return 'task-${requests.length}';
  }
}

class _OgInstallHarness {
  _OgInstallHarness({
    this.launchCompleted = true,
    this.linglongEnvOk = true,
    this.enqueueTaskId = 'task-1',
    Future<AppDetail> Function(String appId)? loadDetail,
  }) : _loadDetail = loadDetail {
    controller = OgInstallController(
      isLaunchCompleted: () => launchCompleted,
      isLinglongEnvOk: () => linglongEnvOk,
      loadAppDetail: (appId) async {
        detailRequests.add(appId);
        final loadDetail = _loadDetail;
        if (loadDetail != null) {
          return loadDetail(appId);
        }
        return AppDetail(
          appId: appId,
          name: 'Example App',
          version: '1.0.0',
          icon: 'https://example.com/icon.png',
        );
      },
      enqueueInstall: (params) {
        enqueuedParams.add(params);
        return enqueueTaskId;
      },
      emitEvent: events.add,
    );
  }

  bool launchCompleted;
  bool linglongEnvOk;
  String enqueueTaskId;

  final Future<AppDetail> Function(String appId)? _loadDetail;
  final List<String> detailRequests = [];
  final List<EnqueueAppOperationParams> enqueuedParams = [];
  final List<OgInstallEvent> events = [];

  late final OgInstallController controller;
}
