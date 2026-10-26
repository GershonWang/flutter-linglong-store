import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/domain/models/linglong_app_analysis.dart';
import 'package:linglong_store/domain/repositories/linglong_app_analysis_repository.dart';
import 'package:linglong_store/presentation/widgets/linglong_environment_management/disk_analysis_tab.dart';
import 'package:linglong_store/presentation/widgets/app_anchored_menu.dart';
import 'package:linglong_store/presentation/widgets/linglong_environment_management/environment_management_components.dart';

/// 仅记录可见页面是否请求扫描，不执行系统命令。
class _Repository implements LinglongAppAnalysisRepository {
  /// 允许列表交互用完整快照验证，不扫描真实仓库。
  _Repository({this.modules = const []});
  final List<LinglongModuleUsage> modules;
  int count = 0;
  @override
  Future<LinglongDiskUsage> analyzeSize() async {
    count++;
    return LinglongDiskUsage(
      modules: modules,
      calculatedExclusiveSize: 0,
      calculatedSharedSize: 0,
      calculatedLogicalSize: 0,
      calculatedActualSize: 0,
      repositoryRealSize: 0,
    );
  }

  @override
  Future<List<LinglongDependencyNode>> analyzeDepends(String appRef) async =>
      [];
}

void main() {
  for (final language in ['fr', 'de']) {
    testWidgets('四页签在$language长标签和1.5字体下无溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 180));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: DefaultTabController(
                length: 4,
                child: EnvironmentManagementSegmentedTabBar(
                  isBusy: false,
                  showDiskAnalysis: true,
                  onRefresh: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('搜索与维度排序只处理缓存不重复扫描', (tester) async {
    final repository = _Repository(
      modules: [
        const LinglongModuleUsage(
          id: 'a',
          name: 'Alpha',
          version: '1',
          channel: 'main',
          module: 'binary',
          exclusiveSize: 1,
          sharedSize: 0,
          logicalSize: 1,
          actualSize: 1,
        ),
        const LinglongModuleUsage(
          id: 'z',
          name: 'Zeta',
          version: '1',
          channel: 'main',
          module: 'binary',
          exclusiveSize: 2,
          sharedSize: 0,
          logicalSize: 2,
          actualSize: 2,
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
          linglongCliCapabilitiesProvider.overrideWithValue(
            LinglongCliCapabilities.fromVersion('1.14.0'),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DiskAnalysisTab(active: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Zeta')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    await tester.tap(find.byType(AppAnchoredMenuButton<String>));
    await tester.pumpAndSettle();
    final menuContext = tester.element(
      find.byType(AppAnchoredMenuButton<String>),
    );
    await tester.tap(find.text(AppLocalizations.of(menuContext)!.packageName));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Zeta')).dy),
    );
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Zeta'), findsNothing);
    expect(repository.count, 1);
  });
  testWidgets('隐藏页签不预加载，切换可见后才扫描', (tester) async {
    final repository = _Repository();
    var active = false;
    late StateSetter setActive;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
          linglongCliCapabilitiesProvider.overrideWithValue(
            LinglongCliCapabilities.fromVersion('1.14.0'),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setter) {
                setActive = setter;
                return DiskAnalysisTab(active: active);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.count, 0);
    setActive(() => active = true);
    await tester.pumpAndSettle();
    expect(repository.count, 1);
    expect(find.text('No analysis data'), findsOneWidget);
  });
}
