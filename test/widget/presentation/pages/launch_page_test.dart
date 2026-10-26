import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linglong_store/application/providers/launch_provider.dart';
import 'package:linglong_store/application/providers/linglong_env_provider.dart';
import 'package:linglong_store/core/config/theme.dart';
import 'package:linglong_store/core/config/routes.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/presentation/pages/launch/launch_page.dart';
import 'package:linglong_store/presentation/widgets/linglong_env_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUpAll(() async {
    await AppLogger.init();
  });

  testWidgets(
    'launch page displays dynamic version from PackageInfo, not hardcoded v1.0.0',
    (tester) async {
      // Mock PackageInfo 返回测试版本号
      PackageInfo.setMockInitialValues(
        appName: 'linglong_store',
        packageName: 'linglong_store',
        version: '3.1.2',
        buildNumber: '1',
        buildSignature: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            launchSequenceProvider.overrideWith(() => _IdleLaunchSequence()),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LaunchPage(),
          ),
        ),
      );

      // 等待异步操作完成（版本号获取）
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // 验证不应该显示硬编码的 v1.0.0
      expect(find.text('v1.0.0'), findsNothing);

      // 验证应该显示 PackageInfo 的真实版本号，而不是配置里的硬编码 fallback。
      const expectedVersion = 'v3.1.2';
      expect(find.text(expectedVersion), findsOneWidget);
    },
  );

  testWidgets(
    'launch page does not show the environment dialog for warning-only state',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'linglong_store',
        packageName: 'linglong_store',
        version: '3.1.2',
        buildNumber: '1',
        buildSignature: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            launchSequenceProvider.overrideWith(() => _IdleLaunchSequence()),
            linglongEnvProvider.overrideWith(() => _WarningLinglongEnv()),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LaunchPage(),
          ),
        ),
      );

      await tester.pumpAndSettle(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('launch page uses filled retry button in error state', (
    tester,
  ) async {
    final errorSequence = _ErrorLaunchSequence();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [launchSequenceProvider.overrideWith(() => errorSequence)],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LaunchPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final retryButton = find.ancestor(
      of: find.text('重试'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );

    expect(retryButton, findsOneWidget);

    await tester.tap(retryButton);
    await tester.pump();

    expect(errorSequence.retried, isTrue);
  });

  testWidgets(
    'unavailable environment reminds after home is mounted only once',
    (tester) async {
      var homeBuilt = false;
      var dialogPushes = 0;
      final observer = _DialogObserver(() {
        // 弹窗附着于首页，不得抢在路由切换前推入启动页的 pageless 栈。
        expect(homeBuilt, isTrue);
        dialogPushes += 1;
      });
      final sequence = _CompletedLaunchSequence();
      final router = GoRouter(
        initialLocation: AppRoutes.launch,
        observers: [observer],
        routes: [
          GoRoute(
            path: AppRoutes.launch,
            builder: (context, state) => const LaunchPage(),
          ),
          GoRoute(
            path: AppRoutes.recommend,
            builder: (context, state) {
              homeBuilt = true;
              return const Scaffold(body: Text('Browse home'));
            },
          ),
          GoRoute(
            path: '/other',
            builder: (context, state) =>
                const Scaffold(body: Text('Other page')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            launchSequenceProvider.overrideWith(() => sequence),
            linglongEnvProvider.overrideWith(() => _UnavailableLinglongEnv()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LaunchPage), findsNothing);
      expect(find.text('Browse home'), findsOneWidget);
      expect(find.byType(LinglongEnvDialog), findsOneWidget);
      expect(dialogPushes, 1);

      await tester.tap(find.text('继续浏览'));
      await tester.pumpAndSettle();
      expect(find.byType(LinglongEnvDialog), findsNothing);
      expect(find.text('Browse home'), findsOneWidget);
      expect(dialogPushes, 1);

      router.go('/other');
      await tester.pumpAndSettle();
      sequence.finishEnvironmentRecovery();
      await tester.pumpAndSettle();
      expect(find.text('Other page'), findsOneWidget);
      expect(dialogPushes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

class _IdleLaunchSequence extends LaunchSequence {
  @override
  LaunchState build() => const LaunchState();

  @override
  Future<void> runSequence() async {}
}

class _ErrorLaunchSequence extends LaunchSequence {
  bool retried = false;

  @override
  LaunchState build() {
    return const LaunchState(hasError: true, errorMessage: '启动失败');
  }

  @override
  Future<void> runSequence() async {}

  @override
  Future<void> retry() async {
    retried = true;
  }
}

class _WarningLinglongEnv extends LinglongEnv {
  @override
  LinglongEnvState build() {
    return const LinglongEnvState(
      checkState: LinglongEnvCheckState.success,
      result: LinglongEnvCheckResult(
        isOk: true,
        warningMessage: '当前玲珑基础环境版本(1.8.2)过低',
        llCliVersion: '1.8.2',
        repoStatus: RepoStatus.ok,
        checkedAt: 1,
      ),
    );
  }
}

/// 模拟完成浏览启动及后台能力恢复，不执行平台初始化。
class _CompletedLaunchSequence extends LaunchSequence {
  @override
  LaunchState build() => const LaunchState();

  @override
  Future<void> runSequence() async {
    state = const LaunchState(isCompleted: true, isBrowseOnly: true);
  }

  /// 恢复仍保持启动完成，当前页面不可被重新导航到首页。
  void finishEnvironmentRecovery() {
    state = state.copyWith(isBrowseOnly: false);
  }
}

/// 只提供启动检测结果，提醒应直接复用结果而非发起第二轮探测。
class _UnavailableLinglongEnv extends LinglongEnv {
  @override
  LinglongEnvState build() => const LinglongEnvState(
    checkState: LinglongEnvCheckState.success,
    result: LinglongEnvCheckResult(
      isOk: false,
      errorMessage: 'll-cli 未安装或不可用',
      checkedAt: 1,
    ),
  );
}

/// 记录弹窗入栈时机，覆盖导航与下一帧提醒之间的顺序约束。
class _DialogObserver extends NavigatorObserver {
  _DialogObserver(this.onDialogPushed);

  final VoidCallback onDialogPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) onDialogPushed();
  }
}
