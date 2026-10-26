import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/install_queue_provider.dart';
import 'package:linglong_store/application/providers/linglong_environment_management_provider.dart';
import 'package:linglong_store/application/services/linglong_environment_management_service.dart';
import 'package:linglong_store/application/services/linglong_environment_service.dart';
import 'package:linglong_store/core/platform/shell_command_executor.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/domain/models/install_progress.dart';
import 'package:linglong_store/domain/models/install_queue_state.dart';
import 'package:linglong_store/domain/models/install_task.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/models/linglong_environment_management.dart';
import 'package:linglong_store/domain/models/linglong_repository_config.dart';
import 'package:linglong_store/domain/repositories/linglong_repository_management_repository.dart';

void main() {
  // 失败场景保留真实诊断路径，先初始化生产日志依赖。
  setUpAll(AppLogger.init);
  group('LinglongEnvironmentManagement provider', () {
    test('load reads analysis and repository config', () async {
      final service = _FakeManagementService();
      final repository = _FakeRepositoryManagementRepository();
      final container = _createContainer(service, repository);
      addTearDown(container.dispose);

      await container
          .read(linglongEnvironmentManagementProvider.notifier)
          .load();

      final state = container.read(linglongEnvironmentManagementProvider);
      expect(state.status, LinglongEnvironmentManagementStatus.ready);
      expect(state.analysis?.runningAppCount, 0);
      expect(state.repositoryConfig?.defaultRepo, 'stable');
      expect(service.analyzeCallCount, 1);
      expect(repository.getCallCount, 1);
    });

    test(
      'repairOstreeRepository stores result and refreshes analysis',
      () async {
        final service = _FakeManagementService();
        final repository = _FakeRepositoryManagementRepository();
        final container = _createContainer(service, repository);
        addTearDown(container.dispose);

        final result = await container
            .read(linglongEnvironmentManagementProvider.notifier)
            .repairOstreeRepository();

        final state = container.read(linglongEnvironmentManagementProvider);
        expect(result.success, isTrue);
        expect(state.status, LinglongEnvironmentManagementStatus.ready);
        expect(
          state.repairResult?.action,
          LinglongEnvironmentRepairAction.ostreeFsckDelete,
        );
        expect(service.repairOstreeCallCount, 1);
        expect(service.analyzeCallCount, 1);
      },
    );

    test(
      'repairLinglongDataPermissions stores result and refreshes analysis',
      () async {
        final service = _FakeManagementService();
        final repository = _FakeRepositoryManagementRepository();
        final container = _createContainer(service, repository);
        addTearDown(container.dispose);

        final result = await container
            .read(linglongEnvironmentManagementProvider.notifier)
            .repairLinglongDataPermissions();

        final state = container.read(linglongEnvironmentManagementProvider);
        expect(result.success, isTrue);
        expect(state.status, LinglongEnvironmentManagementStatus.ready);
        expect(
          state.repairResult?.action,
          LinglongEnvironmentRepairAction.fixDataPermissions,
        );
        expect(service.repairDataPermissionCallCount, 1);
        expect(service.analyzeCallCount, 1);
      },
    );

    test(
      'moveLinglongStorage is blocked when install queue has active tasks',
      () async {
        final service = _FakeManagementService();
        final repository = _FakeRepositoryManagementRepository();
        final container = _createContainer(
          service,
          repository,
          installQueueState: InstallQueueState(
            currentTask: _installTask(
              id: 'task-1',
              appId: 'org.example.demo',
              appName: 'Demo',
              status: InstallStatus.installing,
            ),
            isProcessing: true,
          ),
        );
        addTearDown(container.dispose);

        final result = await container
            .read(linglongEnvironmentManagementProvider.notifier)
            .moveLinglongStorage('/data/linglong');

        final state = container.read(linglongEnvironmentManagementProvider);
        expect(result.success, isFalse);
        expect(
          result.code,
          LinglongEnvironmentRepairResultCode
              .storageMoveBlockedByNamedActiveTask,
        );
        expect(result.subject, 'Demo');
        expect(state.status, LinglongEnvironmentManagementStatus.failed);
        expect(state.repairResult?.success, isFalse);
        expect(service.moveStorageCallCount, 0);
      },
    );

    test(
      'addRepository delegates to repository and refreshes config',
      () async {
        final service = _FakeManagementService();
        final repository = _FakeRepositoryManagementRepository();
        final container = _createContainer(service, repository);
        addTearDown(container.dispose);

        await container
            .read(linglongEnvironmentManagementProvider.notifier)
            .addRepository(
              name: 'test',
              url: 'https://repo.example.com',
              alias: 'test-alias',
            );

        final state = container.read(linglongEnvironmentManagementProvider);
        expect(state.status, LinglongEnvironmentManagementStatus.ready);
        expect(repository.addCalls.single, {
          'name': 'test',
          'url': 'https://repo.example.com',
          'alias': 'test-alias',
        });
        expect(repository.getCallCount, 1);
        expect(state.repositoryConfig?.repos.single.name, 'stable');
      },
    );

    test('镜像写入后回读失败必须向调用方报告失败', () async {
      final repository = _FakeRepositoryManagementRepository()
        ..readError = StateError('readback failed');
      final container = _createContainer(_FakeManagementService(), repository);
      addTearDown(container.dispose);
      await expectLater(
        container
            .read(linglongEnvironmentManagementProvider.notifier)
            .setRepositoryMirror('stable', enabled: true),
        throwsA(isA<Exception>()),
      );
      expect(
        container.read(linglongEnvironmentManagementProvider).errorMessage,
        contains('readback failed'),
      );
    });
    test('地区开启关闭重新开启及自动选择均回读确认', () async {
      final repository = _FakeRepositoryManagementRepository();
      final container = _createContainer(
        _FakeManagementService(),
        repository,
        cliVersion: '1.14.0',
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        linglongEnvironmentManagementProvider.notifier,
      );
      await notifier.setRepositoryMirror('stable', enabled: true, region: 'CN');
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .repositoryConfig!
            .repos
            .single
            .region,
        'CN',
      );
      await notifier.setRepositoryMirror('stable', enabled: false);
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .repositoryConfig!
            .repos
            .single
            .region,
        'CN',
      );
      await notifier.setRepositoryMirror('stable', enabled: true, region: 'CN');
      await notifier.setRepositoryMirror('stable', enabled: true);
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .repositoryConfig!
            .repos
            .single
            .region,
        isNull,
      );
      expect(repository.mirrorCalls, [
        {'enabled': true, 'region': 'CN'},
        {'enabled': false, 'region': null},
        {'enabled': true, 'region': 'CN'},
        {'enabled': true, 'region': null},
      ]);
    });

    test('低版请求仍只执行旧镜像开关，不透传地区', () async {
      final repository = _FakeRepositoryManagementRepository();
      final container = _createContainer(
        _FakeManagementService(),
        repository,
        cliVersion: '1.13.0',
      );
      addTearDown(container.dispose);
      await container
          .read(linglongEnvironmentManagementProvider.notifier)
          .setRepositoryMirror('stable', enabled: true, region: 'CN');
      expect(repository.mirrorCalls.single, {'enabled': true, 'region': null});
    });

    test('回读与请求不一致时不能成功并标记仓库状态未知', () async {
      final repository = _FakeRepositoryManagementRepository()
        ..ignoreMirrorMutation = true;
      final container = _createContainer(
        _FakeManagementService(),
        repository,
        cliVersion: '1.14.0',
      );
      addTearDown(container.dispose);
      await expectLater(
        container
            .read(linglongEnvironmentManagementProvider.notifier)
            .setRepositoryMirror('stable', enabled: true, region: 'CN'),
        throwsA(isA<LinglongMirrorConfirmationException>()),
      );
      final state = container.read(linglongEnvironmentManagementProvider);
      expect(state.status, LinglongEnvironmentManagementStatus.failed);
      expect(state.unconfirmedMirrorAlias, 'stable');
    });
    test('连续两个仓库写入后回读失败保持整体快照未确认，完整刷新才清除', () async {
      final repository = _FakeRepositoryManagementRepository()
        ..extraRepos = [
          const LinglongRepoInfo(
            name: 'second',
            url: 'https://repo.example.com',
            isMirrorEnabled: true,
            region: 'EU',
          ),
        ];
      final container = _createContainer(
        _FakeManagementService(),
        repository,
        cliVersion: '1.14.0',
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        linglongEnvironmentManagementProvider.notifier,
      );
      await notifier.load();
      repository.readError = StateError('cannot confirm config');
      for (final name in ['stable', 'second']) {
        await expectLater(
          notifier.setRepositoryMirror(name, enabled: true, region: 'US'),
          throwsA(isA<LinglongMirrorConfirmationException>()),
        );
      }
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .unconfirmedMirrorAlias,
        'second',
      );
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .repositoryConfig!
            .repos,
        hasLength(2),
      );
      repository.readError = null;
      await notifier.refreshRepositoryConfig();
      expect(
        container
            .read(linglongEnvironmentManagementProvider)
            .unconfirmedMirrorAlias,
        isNull,
      );
    });
  });
}

ProviderContainer _createContainer(
  _FakeManagementService service,
  _FakeRepositoryManagementRepository repository, {
  InstallQueueState installQueueState = const InstallQueueState(),
  String? cliVersion,
}) {
  return ProviderContainer(
    overrides: [
      linglongCliCapabilitiesProvider.overrideWithValue(
        LinglongCliCapabilities.fromVersion(cliVersion),
      ),
      linglongEnvironmentManagementServiceProvider.overrideWithValue(service),
      linglongRepositoryManagementRepositoryProvider.overrideWithValue(
        repository,
      ),
      installQueueProvider.overrideWith(
        () => _TestInstallQueue(initialState: installQueueState),
      ),
    ],
  );
}

class _FakeManagementService extends LinglongEnvironmentManagementService {
  _FakeManagementService()
    : super(
        executor: ShellCommandExecutor(
          runner: const _FixedShellCommandRunner(),
        ),
        environmentService: LinglongEnvironmentService(
          executor: ShellCommandExecutor(
            runner: const _FixedShellCommandRunner(),
          ),
        ),
      );

  int analyzeCallCount = 0;
  int repairOstreeCallCount = 0;
  int repairDataPermissionCallCount = 0;
  int moveStorageCallCount = 0;

  @override
  Future<LinglongEnvironmentAnalysis> analyzeEnvironment() async {
    analyzeCallCount += 1;
    return LinglongEnvironmentAnalysis(
      envResult: const LinglongEnvCheckResult(
        isOk: true,
        llCliVersion: '1.12.2',
        repoStatus: RepoStatus.ok,
        checkedAt: 1,
      ),
      storage: const LinglongStorageInfo(rootPath: '/var/lib/linglong'),
      dataPermission: const LinglongDataPermissionCheckResult(
        isAvailable: true,
        isOk: true,
      ),
      ostree: const LinglongOstreeCheckResult(isAvailable: true, isOk: true),
      issues: const [],
      runningAppCount: 0,
      analyzedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
  }

  @override
  Future<LinglongEnvironmentRepairResult> repairOstreeRepository({
    String? logFilePath,
  }) async {
    repairOstreeCallCount += 1;
    return const LinglongEnvironmentRepairResult(
      action: LinglongEnvironmentRepairAction.ostreeFsckDelete,
      success: true,
      code: LinglongEnvironmentRepairResultCode.localDataRepairCompleted,
      logFilePath: '/tmp/repair.log',
    );
  }

  @override
  Future<LinglongEnvironmentRepairResult> repairLinglongDataPermissions({
    String? logFilePath,
  }) async {
    repairDataPermissionCallCount += 1;
    return const LinglongEnvironmentRepairResult(
      action: LinglongEnvironmentRepairAction.fixDataPermissions,
      success: true,
      code: LinglongEnvironmentRepairResultCode.dataPermissionRepairCompleted,
      logFilePath: '/tmp/permission.log',
    );
  }

  @override
  Future<LinglongEnvironmentRepairResult> moveLinglongStorage(
    String targetPath, {
    String? logFilePath,
  }) async {
    moveStorageCallCount += 1;
    return const LinglongEnvironmentRepairResult(
      action: LinglongEnvironmentRepairAction.moveStorageRoot,
      success: true,
      code: LinglongEnvironmentRepairResultCode.storageMoveCompleted,
      logFilePath: '/tmp/move.log',
    );
  }
}

class _FakeRepositoryManagementRepository
    implements LinglongRepositoryManagementRepository {
  /// 模拟提交完成后的配置读取失败，验证不能误报成功。
  Object? readError;

  /// 模拟后端未接受新配置，避免写命令成功被当成配置成功。
  bool ignoreMirrorMutation = false;

  /// 记录镜像边界参数，避免使用真实系统配置。
  final mirrorCalls = <Map<String, Object?>>[];

  /// 第二仓库用于验证连续回读失败不能恢复过期条目的确认语义。
  List<LinglongRepoInfo> extraRepos = const [];

  /// 遵循上游关闭保留地区、自动清除地区的配置快照。
  LinglongRepoInfo repo = const LinglongRepoInfo(
    name: 'stable',
    url: 'https://repo.example.com',
    priority: '0',
  );
  int getCallCount = 0;
  final addCalls = <Map<String, String?>>[];

  @override
  Future<LinglongRepositoryConfig> getRepositoryConfig() async {
    getCallCount += 1;
    if (readError != null) throw readError!;
    return LinglongRepositoryConfig(
      defaultRepo: 'stable',
      repos: [repo, ...extraRepos],
    );
  }

  @override
  Future<String> addRepository({
    required String name,
    required String url,
    String? alias,
  }) async {
    addCalls.add({'name': name, 'url': url, 'alias': alias});
    return 'ok';
  }

  @override
  Future<String> removeRepository(String aliasOrName) async => 'ok';

  @override
  Future<String> setDefaultRepository(String aliasOrName) async => 'ok';

  @override
  Future<String> setRepositoryMirror(
    String aliasOrName, {
    required bool enabled,
    String? region,
  }) async {
    mirrorCalls.add({'enabled': enabled, 'region': region});
    if (!ignoreMirrorMutation) {
      repo = repo.copyWith(
        isMirrorEnabled: enabled,
        region: enabled ? region : repo.region,
      );
    }
    return 'ok';
  }

  @override
  Future<String> setRepositoryPriority(
    String aliasOrName,
    int priority,
  ) async => 'ok';

  @override
  Future<String> updateRepository({
    required String aliasOrName,
    required String url,
  }) async => 'ok';
}

class _FixedShellCommandRunner implements ShellCommandRunner {
  const _FixedShellCommandRunner();

  @override
  Future<ShellCommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(minutes: 5),
    Map<String, String>? environment,
    ShellCommandLogOptions? logOptions,
  }) async {
    return const ShellCommandResult(stdout: '', stderr: '', exitCode: 0);
  }
}

InstallTask _installTask({
  required String id,
  required String appId,
  required String appName,
  required InstallStatus status,
}) {
  return InstallTask(
    id: id,
    appId: appId,
    appName: appName,
    status: status,
    createdAt: 1,
  );
}

class _TestInstallQueue extends InstallQueue {
  _TestInstallQueue({required InstallQueueState initialState})
    : _initialState = initialState;

  final InstallQueueState _initialState;

  @override
  InstallQueueState build() => _initialState;

  @override
  Future<void> startProcessing() async {}
}
