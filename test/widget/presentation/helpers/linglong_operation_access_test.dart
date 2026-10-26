/// 缺少玲珑环境时用户操作入口的兼容回归测试。
///
/// 验证点击才提示、关闭提示不产生本机副作用，以及环境就绪后原操作仍可执行。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/install_queue_provider.dart';
import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/application/providers/network_speed_provider.dart';
import 'package:linglong_store/application/services/app_uninstall_service.dart';
import 'package:linglong_store/core/config/theme.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/domain/models/app_operation_target_snapshot.dart';
import 'package:linglong_store/domain/models/install_button_state.dart';
import 'package:linglong_store/domain/models/install_queue_state.dart';
import 'package:linglong_store/domain/models/install_task.dart';
import 'package:linglong_store/domain/models/install_progress.dart';
import 'package:linglong_store/domain/models/installed_app.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/repositories/linglong_cli_repository.dart';
import 'package:linglong_store/presentation/helpers/app_uninstall_flow.dart';
import 'package:linglong_store/presentation/pages/app_detail/app_detail_page_actions.dart';
import 'package:linglong_store/presentation/widgets/app_card_actions.dart';
import 'package:linglong_store/presentation/widgets/download_manager/download_manager_task_content.dart';
import 'package:linglong_store/presentation/widgets/download_manager_dialog.dart';
import 'package:linglong_store/presentation/widgets/linglong_env_dialog.dart';

/// 测试操作目标；无需远端详情或真实本机安装实例。
const _app = InstalledApp(
  appId: 'org.example.demo',
  name: 'Demo',
  version: '1.0.0',
);

/// 保留环境快照，确保测试过程不会执行真实环境探测。
class _FixedEnvironment extends LinglongEnv {
  /// 注入当前环境是否可操作，并可模拟用户已选择浏览。
  _FixedEnvironment({required this.available, this.skipped = false});

  /// 当前已完成探测的真实环境能力。
  final bool available;

  /// 浏览选择不应影响真实环境授权结果。
  final bool skipped;

  @override
  LinglongEnvState build() => LinglongEnvState(
    checkState: LinglongEnvCheckState.success,
    wasSkipped: skipped,
    result: LinglongEnvCheckResult(
      isOk: available,
      errorMessage: available ? null : 'll-cli 未安装或不可用',
      checkedAt: 1,
    ),
  );
}

/// 记录入队请求，不启动安装进程、持久化或全局副作用。
class _RecordingQueue extends InstallQueue {
  /// 注入历史记录，验证重试被阻止后原记录仍然保留。
  _RecordingQueue({this.initialState = const InstallQueueState()});

  /// 用于断言未被操作更改的原队列快照。
  final InstallQueueState initialState;

  /// 记录操作是否越过环境门禁。
  final List<InstallTaskKind> requests = <InstallTaskKind>[];

  /// 重试调用必须在环境恢复后才发生。
  final List<String> retries = <String>[];

  @override
  InstallQueueState build() => initialState;

  @override
  void retryFailedTask(String taskId) {
    retries.add(taskId);
  }

  @override
  String enqueueOperation({
    required InstallTaskKind kind,
    required String appId,
    required String appName,
    String? icon,
    String? version,
    AppOperationTargetSnapshot? target,
    bool force = false,
    bool? noAutoPrune,
  }) {
    requests.add(kind);
    return 'test-task';
  }
}

/// 仅记录用户启动动作；其它端口一旦被误调用就由 Fake 抛错。
class _RecordingCli extends Fake implements LinglongCliRepository {
  /// 用于检测未就绪环境是否误启动应用。
  final List<String> launches = <String>[];

  @override
  Future<void> runApp(String appId) async {
    launches.add(appId);
  }
}

/// 创建带真实环境提示 UI 的动作测试宿主。
Future<void> _pumpAction(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context, WidgetRef ref) action,
  required _RecordingQueue queue,
  required _RecordingCli cli,
  bool available = false,
  bool skipped = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        linglongEnvProvider.overrideWith(
          () => _FixedEnvironment(available: available, skipped: skipped),
        ),
        installQueueProvider.overrideWith(() => queue),
        linglongCliRepositoryProvider.overrideWithValue(cli),
        networkSpeedProvider.overrideWithValue(const NetworkSpeed()),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => action(context, ref),
              child: const Text('操作'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final buttonState in <InstallButtonState>[
    InstallButtonState.notInstalled,
    InstallButtonState.update,
    InstallButtonState.open,
  ]) {
    testWidgets('卡片 $buttonState 点击才提示，关闭后不入队或启动', (tester) async {
      final queue = _RecordingQueue();
      final cli = _RecordingCli();
      await _pumpAction(
        tester,
        queue: queue,
        cli: cli,
        skipped: true,
        action: (context, ref) => handleAppCardPrimaryAction(
          context: context,
          ref: ref,
          buttonState: buttonState,
          appId: _app.appId,
          appName: _app.name,
          sourceIconKey: GlobalKey(),
        ),
      );

      expect(find.byType(LinglongEnvDialog), findsNothing);
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(queue.requests, isEmpty);
      expect(cli.launches, isEmpty);
      expect(find.byType(LinglongEnvDialog), findsNothing);
    });
  }

  /// 详情所有本机动作共用真实 guard，防止历史版本和快捷方式等次级入口遗漏。
  final detailActions =
      <
        String,
        Future<void> Function(
          AppDetailPageActions actions,
          BuildContext context,
        )
      >{
        '安装': (actions, context) => actions.handlePrimaryAction(
          context,
          app: _app,
          buttonState: InstallButtonState.notInstalled,
          installSourceKey: GlobalKey(),
        ),
        '更新': (actions, context) => actions.handlePrimaryAction(
          context,
          app: _app,
          buttonState: InstallButtonState.update,
          installSourceKey: GlobalKey(),
        ),
        '历史版本安装': (actions, context) => actions.installVersion(
          context,
          app: _app,
          version: '0.9.0',
          installSourceKey: GlobalKey(),
        ),
        '打开': (actions, context) => actions.openApp(context, _app),
        '快捷方式': (actions, context) => actions.createShortcut(context, _app),
        '头部卸载': (actions, context) =>
            actions.showHeaderUninstallDialog(context, _app),
        '版本卸载': (actions, context) => actions.uninstallVersion(
          context,
          currentApp: _app,
          detail: null,
          version: _app.version,
        ),
      };
  for (final entry in detailActions.entries) {
    testWidgets('详情${entry.key}缺环境时展示引导，不读本机数据或执行操作', (tester) async {
      final queue = _RecordingQueue();
      final cli = _RecordingCli();
      await _pumpAction(
        tester,
        queue: queue,
        cli: cli,
        action: (context, ref) =>
            entry.value(AppDetailPageActions(ref), context),
      );

      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(queue.requests, isEmpty);
      expect(cli.launches, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('统一卸载流程缺环境时不请求确认或修改本机状态', (tester) async {
    final events = <String>[];
    final service = AppUninstallService(
      readRunningApps: () {
        events.add('read-running');
        return const [];
      },
      killRunningApp: (_) async => true,
      uninstallApp: (_, version) async => events.add('uninstall'),
      removeInstalledApp: (_, version) => events.add('remove'),
      syncAfterUninstall: () async => events.add('sync'),
    );
    bool? result;
    await _pumpAction(
      tester,
      queue: _RecordingQueue(),
      cli: _RecordingCli(),
      action: (context, ref) async {
        result = await AppUninstallFlow.run(context, _app, service, ref: ref);
      },
    );

    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    expect(find.byType(LinglongEnvDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(events, isEmpty);
  });

  testWidgets('健康环境卡片安装正常入队，不展示环境弹窗', (tester) async {
    final queue = _RecordingQueue();
    await _pumpAction(
      tester,
      queue: queue,
      cli: _RecordingCli(),
      available: true,
      action: (context, ref) => handleAppCardPrimaryAction(
        context: context,
        ref: ref,
        buttonState: InstallButtonState.notInstalled,
        appId: _app.appId,
        appName: _app.name,
        sourceIconKey: GlobalKey(),
      ),
    );

    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();

    expect(queue.requests, <InstallTaskKind>[InstallTaskKind.install]);
    expect(find.byType(LinglongEnvDialog), findsNothing);
  });

  for (final retry in <bool>[false, true]) {
    testWidgets('下载历史${retry ? '重试' : '打开'}缺环境时只提示，保留历史记录', (tester) async {
      final task = InstallTask(
        id: 'history-task',
        appId: _app.appId,
        appName: _app.name,
        status: retry ? InstallStatus.failed : InstallStatus.success,
        createdAt: 1,
      );
      final queue = _RecordingQueue(
        initialState: InstallQueueState(history: <InstallTask>[task]),
      );
      final cli = _RecordingCli();
      await _pumpAction(
        tester,
        queue: queue,
        cli: cli,
        action: (context, ref) => showDownloadManagerDialog(context),
      );
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      final content = tester.widget<DownloadManagerTaskContent>(
        find.byType(DownloadManagerTaskContent),
      );
      if (retry) {
        content.onRetryHistory(task);
      } else {
        content.onOpenHistory(task);
      }
      await tester.pumpAndSettle();

      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(cli.launches, isEmpty);
      expect(queue.retries, isEmpty);
      expect(queue.initialState.history.single.id, task.id);
    });
  }
}
