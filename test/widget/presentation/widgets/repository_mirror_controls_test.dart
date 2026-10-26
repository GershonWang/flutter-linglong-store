/// 仓库镜像控件的版本、选择与未知状态交互验证。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/linglong_environment_management_provider.dart';
import 'package:linglong_store/core/config/theme.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/models/linglong_repository_config.dart';
import 'package:linglong_store/presentation/widgets/linglong_environment_management/repository_management_tab.dart';

/// 纯展示组件通过真实菜单交互验证，不执行系统命令。
void main() {
  testWidgets('地区菜单提供自动与 CN US EU，选择值交给统一入口', (tester) async {
    final selected = <String?>[];
    await _pump(tester, onRegion: (_, region) => selected.add(region));
    for (final choice in {
      '中国 (CN)': 'CN',
      '美国 (US)': 'US',
      '欧洲 (EU)': 'EU',
      '自动选择': null,
    }.entries) {
      await tester.tap(find.byKey(const ValueKey('mirror-region-stable')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice.key).last);
      await tester.pumpAndSettle();
      expect(selected.last, choice.value);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('低版本不展示地区入口', (tester) async {
    await _pump(tester, supported: false);
    expect(find.text('镜像地区'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('任一配置未确认时完整旧快照的镜像状态均为未知', (tester) async {
    await _pump(tester, unconfirmedAlias: 'second', twoRepos: true);
    expect(find.text('镜像状态未知'), findsNWidgets(4));
    expect(
      tester
          .widgetList<Switch>(find.byType(Switch))
          .every((widget) => !widget.value),
      isTrue,
    );
  });

  testWidgets('提交未确认时开关不能把旧地区回写覆盖新地区', (tester) async {
    final toggled = <bool>[];
    await _pump(
      tester,
      unconfirmedAlias: 'stable',
      onToggle: (_, {required enabled}) => toggled.add(enabled),
    );
    await tester.tap(find.byKey(const ValueKey('mirror-switch-stable')));
    await tester.pump();
    expect(toggled, isEmpty);
  });

  testWidgets('窄窗口 RTL 和大字体的地区控件不会溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, locale: const Locale('ar'), scale: 1.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('初次未知快照的地区标签与菜单不能冒充自动模式', (tester) async {
    await _pump(tester, initialUnknown: true);
    expect(find.text('镜像状态未知'), findsNWidgets(2));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('mirror-region-stable')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('英文地区菜单及真实组件视觉验收', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    final previousDisableShadows = debugDisableShadows;
    if (Platform.environment['LL_STORE_MIRROR_CAPTURE'] == '1') {
      // 截图保留真实菜单阴影，避免测试框架把阴影替换成黑色调试描边。
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousDisableShadows);
      await tester.runAsync(() async {
        final bytes = await File(
          '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        ).readAsBytes();
        await (FontLoader(
          'MirrorTest',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        final icons = await File(
          '/home/han/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons)))).load();
      });
    }
    await _pump(tester, locale: const Locale('en'), captureKey: key);
    await tester.tap(find.byKey(const ValueKey('mirror-region-stable')));
    await tester.pumpAndSettle();
    expect(find.text('United States (US)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (Platform.environment['LL_STORE_MIRROR_CAPTURE'] == '1') {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/ll-cli-mirror-regions.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      // Flutter 在 tearDown 前校验绘制开关，因此截图完成立即恢复默认值。
      debugDisableShadows = previousDisableShadows;
    }
  });
}

/// 固定仓库快照模拟回读成功和失败，避免 Provider 订阅掩盖布局问题。
Future<void> _pump(
  WidgetTester tester, {
  bool supported = true,
  bool twoRepos = false,
  bool initialUnknown = false,
  GlobalKey? captureKey,
  String? unconfirmedAlias,
  Locale locale = const Locale('zh'),
  double scale = 1,
  void Function(LinglongRepoInfo, String?)? onRegion,
  void Function(LinglongRepoInfo, {required bool enabled})? onToggle,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: Platform.environment['LL_STORE_MIRROR_CAPTURE'] == '1'
            ? AppTheme.lightTheme.copyWith(
                textTheme: AppTheme.lightTheme.textTheme.apply(
                  fontFamily: 'MirrorTest',
                ),
              )
            : AppTheme.lightTheme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: RepositoryManagementTab(
              supportsMirrorRegion: supported,
              state: LinglongEnvironmentManagementState(
                status: LinglongEnvironmentManagementStatus.ready,
                unconfirmedMirrorAlias: unconfirmedAlias,
                repositoryConfig: LinglongRepositoryConfig(
                  defaultRepo: 'stable',
                  repos: [
                    LinglongRepoInfo(
                      name: 'stable',
                      url: 'https://repo.example.com',
                      priority: '0',
                      isMirrorEnabled: initialUnknown ? null : true,
                      region: initialUnknown ? null : 'CN',
                    ),
                    if (twoRepos)
                      const LinglongRepoInfo(
                        name: 'second',
                        url: 'https://repo.example.com',
                        priority: '0',
                        isMirrorEnabled: true,
                        region: 'US',
                      ),
                  ],
                ),
              ),
              onAddRepository: () {},
              onUpdateRepository: (_) {},
              onRemoveRepository: (_) {},
              onSetDefaultRepository: (_) {},
              onSetPriority: (_) {},
              onSetMirror: onToggle ?? (_, {required enabled}) {},
              onSetMirrorRegion: onRegion,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
