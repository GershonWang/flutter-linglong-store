/// 验证商店体验模式不会查询本机玲珑，并在环境修复后恢复受控刷新。
///
/// 这些边界同时保护页面语义与性能：缺环境时不能沿用旧安装快照、
/// 不能反复启动失败 CLI，环境切换前的在途响应也不能重新填回本机数据。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:linglong_store/application/providers/app_search_index_provider.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/ignored_updates_provider.dart';
import 'package:linglong_store/application/providers/installed_apps_provider.dart';
import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/application/providers/running_process_provider.dart';
import 'package:linglong_store/application/providers/setting_provider.dart';
import 'package:linglong_store/application/providers/update_apps_provider.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/core/platform/cli_executor.dart';
import 'package:linglong_store/domain/models/app_detail.dart';
import 'package:linglong_store/domain/models/installed_app.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/models/running_app.dart';
import 'package:mockito/mockito.dart';

import '../../../mocks/mock_classes.mocks.dart';

/// 用于已安装、更新与进程快照的稳定测试条目。
const _installed = InstalledApp(
  appId: 'org.example.demo',
  name: 'Demo',
  version: '1.0.0',
);

/// 已运行应用快照用于验证缺环境时停止操作也不会执行 CLI。
const _running = RunningApp(
  id: 'container-1',
  appId: 'org.example.demo',
  name: 'Demo',
  version: '1.0.0',
  arch: 'x86_64',
  channel: 'main',
  source: 'main',
  pid: 1,
  containerId: 'container-1',
);

void main() {
  late Directory cacheDirectory;

  setUpAll(() async {
    await AppLogger.init();
    cacheDirectory = await Directory.systemTemp.createTemp('env-compatibility');
    Hive.init(cacheDirectory.path);
    await Hive.openLazyBox('cache');
  });

  tearDown(() async => Hive.lazyBox('cache').clear());

  tearDownAll(() async {
    await Hive.close();
    await cacheDirectory.delete(recursive: true);
  });

  test('缺环境时已安装和更新检查不访问 CLI 或远程更新接口', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    final container = _container(cli, apps, _MutableEnvironment(false));
    addTearDown(container.dispose);

    expect(
      await container.read(installedAppsProvider.notifier).refresh(),
      isFalse,
    );
    await container.read(updateAppsProvider.notifier).checkUpdates();

    verifyNever(
      cli.getInstalledApps(includeBaseService: anyNamed('includeBaseService')),
    );
    verifyNever(apps.checkAppUpdates(any));
    expect(container.read(installedAppsProvider).apps, isEmpty);
    expect(container.read(updateAppsProvider).hasLoadedOnce, isFalse);
  });

  test('环境失效清空本机快照，修复后的显式刷新恢复已安装和更新状态', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    _stubSnapshots(cli, apps);
    final environment = _MutableEnvironment(true);
    final container = _container(cli, apps, environment);
    addTearDown(container.dispose);

    await container.read(installedAppsProvider.notifier).refresh();
    await container.read(updateAppsProvider.notifier).checkUpdates();
    environment.setReady(false);
    expect(container.read(installedAppsProvider).apps, isEmpty);
    expect(container.read(updateAppsProvider).hasLoadedOnce, isFalse);

    environment.setReady(true);
    expect(
      await container.read(installedAppsProvider.notifier).refresh(),
      isTrue,
    );
    await container.read(updateAppsProvider.notifier).checkUpdates();
    expect(container.read(installedAppsProvider).apps, [_installed]);
    expect(container.read(updateAppsProvider).hasLoadedOnce, isTrue);
    verify(
      cli.getInstalledApps(includeBaseService: anyNamed('includeBaseService')),
    ).called(2);
    verify(apps.checkAppUpdates(any)).called(2);
  });

  test('失效环境下晚到的安装快照不会富化或覆盖已清空状态', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    final response = Completer<List<InstalledApp>>();
    when(
      cli.getInstalledApps(includeBaseService: anyNamed('includeBaseService')),
    ).thenAnswer((_) => response.future);
    final environment = _MutableEnvironment(true);
    final container = _container(cli, apps, environment);
    addTearDown(container.dispose);

    final refreshing = container.read(installedAppsProvider.notifier).refresh();
    environment.setReady(false);
    response.complete([_installed]);

    expect(await refreshing, isFalse);
    verifyNever(apps.enrichInstalledAppsWithDetails(any));
    expect(container.read(installedAppsProvider).apps, isEmpty);
    expect(container.read(installedAppsProvider).isLoading, isFalse);
  });

  test('环境已失效时晚到的远程更新结果不能恢复旧本机结论', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    _stubSnapshots(cli, apps);
    final response = Completer<List<AppDetail>>();
    when(apps.checkAppUpdates(any)).thenAnswer((_) => response.future);
    final environment = _MutableEnvironment(true);
    final container = _container(cli, apps, environment);
    addTearDown(container.dispose);
    await container.read(installedAppsProvider.notifier).refresh();

    final checking = container.read(updateAppsProvider.notifier).checkUpdates();
    environment.setReady(false);
    response.complete(const [
      AppDetail(appId: 'org.example.demo', name: 'Demo', version: '2.0.0'),
    ]);
    await checking;

    expect(container.read(updateAppsProvider).apps, isEmpty);
    expect(container.read(updateAppsProvider).hasLoadedOnce, isFalse);
    expect(container.read(updateAppsProvider).isLoading, isFalse);
  });

  test('缺环境不轮询进程或停止旧进程，修复后仅激活页恢复查询', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    _stubSnapshots(cli, apps);
    final environment = _MutableEnvironment(false);
    final container = _container(cli, apps, environment);
    addTearDown(container.dispose);
    final notifier = container.read(runningProcessProvider.notifier);

    notifier.setProcessTabActive(true);
    await notifier.refresh();
    expect(await notifier.killApp(_running), isFalse);
    expect(notifier.isAutoRefreshing, isFalse);
    verifyNever(cli.getRunningApps());
    verifyNever(cli.killApp(any));

    environment.setReady(true);
    await pumpEventQueue();
    expect(container.read(runningProcessProvider).apps, [_running]);
    expect(notifier.isAutoRefreshing, isTrue);
    verify(cli.getRunningApps()).called(1);

    notifier.setPageVisible(false);
    environment.setReady(false);
    environment.setReady(true);
    await pumpEventQueue();
    expect(notifier.isAutoRefreshing, isFalse);
    verifyNoMoreInteractions(cli);
  });

  test('失效环境下晚到的进程快照不恢复列表或定时器', () async {
    final cli = MockLinglongCliRepository();
    final apps = MockAppRepository();
    final response = Completer<List<RunningApp>>();
    when(cli.getRunningApps()).thenAnswer((_) => response.future);
    final environment = _MutableEnvironment(true);
    final container = _container(cli, apps, environment);
    addTearDown(container.dispose);
    final notifier = container.read(runningProcessProvider.notifier);

    final refreshing = notifier.refresh();
    environment.setReady(false);
    response.complete([_running]);
    await refreshing;

    expect(container.read(runningProcessProvider).apps, isEmpty);
    expect(container.read(runningProcessProvider).isInitialLoading, isFalse);
    expect(notifier.isAutoRefreshing, isFalse);
    verifyNever(apps.enrichInstalledAppsWithDetails(any));
  });

  test('缺环境没有索引 CLI，修复后仅加载一次并复用既有缓存格式', () async {
    var calls = 0;
    final environment = _MutableEnvironment(false);
    final container = ProviderContainer(
      overrides: [
        linglongEnvProvider.overrideWith(() => environment),
        appSearchIndexCliLoaderProvider.overrideWithValue(() async {
          calls++;
          return _indexOutput;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(appSearchIndexProvider, (_, _) {});
    await pumpEventQueue();
    expect(calls, 0);
    expect(container.read(appSearchIndexProvider).requireValue, isEmpty);

    environment.setReady(true);
    await pumpEventQueue(times: 50);
    expect(calls, 1);
    expect(
      container.read(appSearchIndexProvider).requireValue.single.appId,
      'org.example.demo',
    );
    final compact =
        await Hive.lazyBox('cache').get('search_index_compact_v1') as String;
    expect(decodeCompactIndex(compact).single.appId, 'org.example.demo');
  });

  test('缺环境仍可使用新鲜搜索缓存而不启动 CLI', () async {
    await Hive.lazyBox('cache').put(
      'search_index_compact_v1',
      encodeCompactIndex(const [
        SearchSuggestionEntry(appId: 'org.example.cached', name: 'Cached'),
      ]),
    );
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        linglongEnvProvider.overrideWith(() => _MutableEnvironment(false)),
        appSearchIndexCliLoaderProvider.overrideWithValue(() async {
          calls++;
          return _indexOutput;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(appSearchIndexProvider, (_, _) {});
    await pumpEventQueue();

    expect(calls, 0);
    expect(
      container.read(appSearchIndexProvider).requireValue.single.appId,
      'org.example.cached',
    );
  });
}

/// 构建具备受控本机仓储和环境状态的容器，避免测试依赖机器真实配置。
ProviderContainer _container(
  MockLinglongCliRepository cli,
  MockAppRepository apps,
  _MutableEnvironment environment,
) => ProviderContainer(
  overrides: [
    linglongCliRepositoryProvider.overrideWithValue(cli),
    appRepositoryProvider.overrideWithValue(apps),
    linglongEnvProvider.overrideWith(() => environment),
    settingProvider.overrideWith(_DefaultSettings.new),
    ignoredUpdatesProvider.overrideWith(_EmptyIgnoredUpdates.new),
  ],
);

/// 常规成功快照供恢复测试使用，缺环境测试仍通过 verifyNever 验证跳过边界。
void _stubSnapshots(MockLinglongCliRepository cli, MockAppRepository apps) {
  when(
    cli.getInstalledApps(includeBaseService: anyNamed('includeBaseService')),
  ).thenAnswer((_) async => [_installed]);
  when(cli.getRunningApps()).thenAnswer((_) async => [_running]);
  when(apps.enrichInstalledAppsWithDetails(any)).thenAnswer(
    (invocation) async =>
        invocation.positionalArguments.first as List<InstalledApp>,
  );
  when(apps.checkAppUpdates(any)).thenAnswer((_) async => []);
}

/// 固定索引输出钉住精简缓存兼容性，无需执行机器上的 ll-cli。
const _indexOutput = CliOutput(
  stdout: '{"stable":[{"id":"org.example.demo","name":"Demo"}]}',
  stderr: '',
  exitCode: 0,
);

/// 环境状态替身模拟安装成功和环境失效的实际 Provider 通知。
class _MutableEnvironment extends LinglongEnv {
  _MutableEnvironment(this.initialReady);

  /// 容器首次构建时的已知检测结果。
  final bool initialReady;

  @override
  LinglongEnvState build() => _state(initialReady);

  /// 模拟环境重新检测，无需执行系统命令。
  void setReady(bool ready) => state = _state(ready);

  /// 固定检测完成结果使测试不依赖安装进度或系统发行版。
  LinglongEnvState _state(bool ready) => LinglongEnvState(
    checkState: LinglongEnvCheckState.success,
    result: LinglongEnvCheckResult(isOk: ready, checkedAt: 1),
  );
}

/// 默认设置替身避免读取 SharedPreferences。
class _DefaultSettings extends Setting {
  @override
  SettingState build() => const SettingState();
}

/// 空忽略记录替身避免恢复测试读取本机偏好设置。
class _EmptyIgnoredUpdates extends IgnoredUpdates {
  @override
  IgnoredUpdatesState build() => const IgnoredUpdatesState.empty();
}
