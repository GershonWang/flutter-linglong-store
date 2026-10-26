/// 验证浏览与玲珑能力门禁的边界，避免跳过提醒误授权或重复探测。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/application/providers/launch_provider.dart';
import 'package:linglong_store/core/config/theme.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/presentation/helpers/linglong_environment_access.dart';
import 'package:linglong_store/presentation/widgets/linglong_env_dialog.dart';

/// 尚未安装 CLI 的标准探测快照。
const _missing = LinglongEnvCheckResult(
  isOk: false,
  errorMessage: 'll-cli 未安装或不可用',
  checkedAt: 1,
);

/// 真正可用于执行受限操作的探测快照。
const _ready = LinglongEnvCheckResult(
  isOk: true,
  llCliVersion: '1.10.0',
  checkedAt: 2,
);

/// 控制检测完成时机，验证异步过程中页面和弹窗生命周期。
class _EnvironmentFake extends LinglongEnv {
  _EnvironmentFake({
    this.initial = _missing,
    this.wasSkipped = false,
    this.isInstalling = false,
  });

  /// 首次快照，null 表示尚未检测。
  final LinglongEnvCheckResult? initial;

  /// 模拟用户曾在启动时选择浏览。
  final bool wasSkipped;

  /// 模拟不可真实取消的系统安装。
  final bool isInstalling;

  /// 测试可延迟首次检测以检查合并及调用页销毁场景。
  Completer<LinglongEnvCheckResult>? checkCompleter;

  /// 用于验证缓存命中时不会启动 CLI 探测。
  int checkCalls = 0;

  /// 用于验证修复重检后放行真实操作。
  int recheckCalls = 0;

  @override
  LinglongEnvState build() => LinglongEnvState(
    result: initial,
    checkState: initial == null
        ? LinglongEnvCheckState.initial
        : LinglongEnvCheckState.success,
    wasSkipped: wasSkipped,
    isInstalling: isInstalling,
    installProgress: 0.5,
  );

  @override
  Future<LinglongEnvCheckResult> checkEnvironment() async {
    checkCalls++;
    state = state.copyWith(checkState: LinglongEnvCheckState.checking);
    final result = await (checkCompleter?.future ?? Future.value(_missing));
    state = state.copyWith(
      result: result,
      checkState: LinglongEnvCheckState.success,
    );
    return result;
  }

  @override
  Future<LinglongEnvCheckResult> recheck() async {
    recheckCalls++;
    state = state.copyWith(
      result: _ready,
      checkState: LinglongEnvCheckState.success,
    );
    return _ready;
  }

  @override
  void skipCheck() {
    state = state.copyWith(wasSkipped: true);
  }

  /// 让测试结束真实忙碌阶段后正常关闭弹窗。
  void completeInstallation() {
    state = state.copyWith(isInstalling: false);
  }
}

/// 环境已经恢复但本机应用、更新及队列仍在补齐的启动编排。
class _RestoringLaunch extends LaunchSequence {
  /// 控制后台恢复完成，确保门禁不会提前返回。
  final Completer<void> pending = Completer<void>();

  /// 验证并发动作共享恢复，避免重复读取或恢复安装队列。
  int restoreCalls = 0;

  @override
  LaunchState build() =>
      const LaunchState(isCompleted: true, isBrowseOnly: true);

  @override
  Future<void> continueAfterEnvCheck() async {
    restoreCalls++;
    await pending.future;
    state = state.copyWith(isBrowseOnly: false);
  }
}

/// 构造真实导航器和状态容器，隔离外部 CLI、网络与窗口服务。
Future<GlobalKey<NavigatorState>> _pumpHarness(
  WidgetTester tester,
  _EnvironmentFake env, {
  required void Function(BuildContext, WidgetRef) onAccess,
  Locale locale = const Locale('zh'),
  TextScaler textScaler = TextScaler.noScaling,
  LaunchSequence? launchSequence,
  Widget? child,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        linglongEnvProvider.overrideWith(() => env),
        if (launchSequence != null)
          launchSequenceProvider.overrideWith(() => launchSequence),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.lightTheme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body:
              child ??
              Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => onAccess(context, ref),
                  child: const Text('access'),
                ),
              ),
        ),
      ),
    ),
  );
  return navigator;
}

void main() {
  testWidgets('environment diagnostics can be copied in the current language', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final env = _EnvironmentFake(
      initial: _missing.copyWith(errorDetail: 'Cannot execute ll-cli (ENOENT)'),
    );
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, _) {
        showLinglongEnvironmentDialog(context);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(LinglongEnvDialog)),
    )!;
    await tester.tap(find.text(l10n.copyErrorMessage));
    await tester.pump();
    expect(clipboardText, contains(l10n.envIssueLlCliUnavailableTitle));
    expect(clipboardText, contains('Cannot execute ll-cli (ENOENT)'));
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'ready cache waits for local runtime restoration before authorizing',
    (tester) async {
      final env = _EnvironmentFake(initial: _ready);
      final launch = _RestoringLaunch();
      var authorized = false;
      late Future<bool> access;
      await _pumpHarness(
        tester,
        env,
        launchSequence: launch,
        onAccess: (context, ref) {
          access = ensureLinglongEnvironment(context, ref);
          access.then((result) => authorized = result);
        },
      );
      await tester.tap(find.text('access'));
      await tester.pump();
      expect(launch.restoreCalls, 1);
      expect(authorized, isFalse);
      expect(env.checkCalls, 0);
      expect(find.byType(LinglongEnvDialog), findsNothing);
      launch.pending.complete();
      await tester.pump();
      expect(await access, isTrue);
      expect(authorized, isTrue);
    },
  );

  testWidgets('successful repair waits for local runtime restoration', (
    tester,
  ) async {
    final env = _EnvironmentFake();
    final launch = _RestoringLaunch();
    var authorized = false;
    late Future<bool> access;
    await _pumpHarness(
      tester,
      env,
      launchSequence: launch,
      onAccess: (context, ref) {
        access = ensureLinglongEnvironment(context, ref);
        access.then((result) => authorized = result);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    expect(find.byType(LinglongEnvDialog), findsNothing);
    expect(launch.restoreCalls, 1);
    expect(authorized, isFalse);
    expect(env.state.result?.isOk, isTrue);
    launch.pending.complete();
    await tester.pump();
    expect(await access, isTrue);
    expect(authorized, isTrue);
  });

  testWidgets('ready cache authorizes without checks or dialogs', (
    tester,
  ) async {
    final env = _EnvironmentFake(initial: _ready);
    late Future<bool> access;
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, ref) {
        access = ensureLinglongEnvironment(context, ref);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pump();
    expect(await access, isTrue);
    expect(env.checkCalls, 0);
    expect(find.byType(LinglongEnvDialog), findsNothing);
  });

  testWidgets('skipped missing environment still denies the operation', (
    tester,
  ) async {
    final env = _EnvironmentFake(wasSkipped: true);
    late Future<bool> access;
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, ref) {
        access = ensureLinglongEnvironment(context, ref);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    expect(env.checkCalls, 0);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('继续浏览'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(await access, isFalse);
    expect(find.text('access'), findsOneWidget);
  });

  testWidgets('concurrent attempts share one detection and one dialog', (
    tester,
  ) async {
    final env = _EnvironmentFake(initial: null);
    final accesses = <Future<bool>>[];
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, ref) {
        accesses.add(ensureLinglongEnvironment(context, ref));
        accesses.add(ensureLinglongEnvironment(context, ref));
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    expect(identical(accesses[0], accesses[1]), isTrue);
    expect(env.checkCalls, 1);
    expect(find.byType(LinglongEnvDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(await Future.wait(accesses), [false, false]);
  });

  testWidgets(
    'startup notice permits browsing without making environment ready',
    (tester) async {
      final env = _EnvironmentFake();
      await _pumpHarness(
        tester,
        env,
        onAccess: (context, _) {
          showLinglongEnvironmentDialog(context, allowBrowse: true);
        },
      );
      await tester.tap(find.text('access'));
      await tester.pumpAndSettle();
      expect(find.text('继续浏览'), findsOneWidget);
      expect(find.text('退出商店'), findsNothing);
      expect(find.textContaining('你可以继续浏览商店'), findsOneWidget);
      await tester.tap(find.text('继续浏览'));
      await tester.pumpAndSettle();
      expect(env.state.wasSkipped, isTrue);
      expect(env.state.result?.isOk, isFalse);
      expect(find.text('access'), findsOneWidget);
    },
  );

  testWidgets('startup and operation prompts reuse the same root dialog', (
    tester,
  ) async {
    final env = _EnvironmentFake();
    late Future<bool> access;
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, ref) {
        showLinglongEnvironmentDialog(context, allowBrowse: true);
        access = ensureLinglongEnvironment(context, ref);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    expect(find.byType(LinglongEnvDialog), findsOneWidget);
    await tester.tap(find.text('继续浏览'));
    await tester.pumpAndSettle();
    expect(await access, isFalse);
  });

  testWidgets('successful recheck authorizes the pending operation', (
    tester,
  ) async {
    final env = _EnvironmentFake(wasSkipped: true);
    late Future<bool> access;
    await _pumpHarness(
      tester,
      env,
      onAccess: (context, ref) {
        access = ensureLinglongEnvironment(context, ref);
      },
    );
    await tester.tap(find.text('access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    expect(await access, isTrue);
    expect(env.recheckCalls, 1);
    expect(env.checkCalls, 0);
    expect(find.byType(LinglongEnvDialog), findsNothing);
  });

  testWidgets(
    'caller disposal during detection uses the surviving root navigator',
    (tester) async {
      final env = _EnvironmentFake(initial: null)
        ..checkCompleter = Completer<LinglongEnvCheckResult>();
      late Future<bool> access;
      final navigator = await _pumpHarness(
        tester,
        env,
        onAccess: (context, ref) {
          access = ensureLinglongEnvironment(context, ref);
        },
      );
      await tester.tap(find.text('access'));
      navigator.currentState!.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('new page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('access'), findsNothing);
      env.checkCompleter!.complete(_missing);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(await access, isFalse);
      expect(find.text('new page'), findsOneWidget);
    },
  );

  testWidgets(
    'system installation cannot be dismissed through back navigation',
    (tester) async {
      final env = _EnvironmentFake(isInstalling: true);
      final navigator = await _pumpHarness(
        tester,
        env,
        onAccess: (context, _) {
          showLinglongEnvironmentDialog(context, allowBrowse: true);
        },
      );
      await tester.tap(find.text('access'));
      await tester.pumpAndSettle();
      expect(find.text('继续浏览'), findsNothing);
      expect(find.text('取消'), findsNothing);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      expect(env.state.isInstalling, isTrue);
      env.completeInstallation();
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续浏览'));
      await tester.pumpAndSettle();
      expect(find.byType(LinglongEnvDialog), findsNothing);
    },
  );

  testWidgets('required view opens the shared repair prompt without probes', (
    tester,
  ) async {
    final env = _EnvironmentFake();
    await _pumpHarness(
      tester,
      env,
      onAccess: (_, _) {},
      child: const LinglongEnvironmentRequiredView(featureName: '我的应用'),
    );
    expect(find.text('我的应用'), findsOneWidget);
    expect(find.text('安装或修复环境'), findsOneWidget);
    await tester.tap(find.text('安装或修复环境'));
    await tester.pumpAndSettle();
    expect(find.byType(LinglongEnvDialog), findsOneWidget);
    expect(env.checkCalls, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('Arabic prompt and required view fit with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(680, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final env = _EnvironmentFake();
    await _pumpHarness(
      tester,
      env,
      locale: const Locale('ar'),
      textScaler: const TextScaler.linear(1.5),
      onAccess: (_, _) {},
      child: const LinglongEnvironmentRequiredView(),
    );
    final context = tester.element(
      find.byType(LinglongEnvironmentRequiredView),
    );
    final l10n = AppLocalizations.of(context)!;
    expect(Directionality.of(context), TextDirection.rtl);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(l10n.configureLinglongEnvironment));
    await tester.pumpAndSettle();
    expect(find.byType(LinglongEnvDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
  });
}
