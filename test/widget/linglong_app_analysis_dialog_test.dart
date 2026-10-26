import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/core/config/theme.dart';
import 'package:linglong_store/domain/models/installed_app.dart';
import 'package:linglong_store/domain/models/linglong_app_analysis.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/domain/repositories/linglong_app_analysis_repository.dart';
import 'package:linglong_store/presentation/widgets/linglong_app_analysis_dialog.dart';
import 'package:linglong_store/presentation/widgets/app_anchored_menu.dart';

/// fixture 只在测试中生成，不污染生产依赖或真实系统。
class _Repository implements LinglongAppAnalysisRepository {
  /// 记录实际所选本地 reference。
  final references = <String>[];
  @override
  Future<LinglongDiskUsage> analyzeSize() async => LinglongDiskUsage(
    modules: [
      for (final version in ['1', '2'])
        LinglongModuleUsage(
          id: 'demo',
          name: 'Example application with a long descriptive name',
          version: version,
          channel: 'main',
          module: 'binary',
          exclusiveSize: 4194304,
          sharedSize: 16777216,
          logicalSize: 20971520,
          actualSize: 12582912,
        ),
    ],
    calculatedExclusiveSize: 8388608,
    calculatedSharedSize: 16777216,
    calculatedLogicalSize: 41943040,
    calculatedActualSize: 25165824,
    repositoryRealSize: 33554432,
  );
  @override
  Future<List<LinglongDependencyNode>> analyzeDepends(String appRef) async {
    references.add(appRef);
    return [
      LinglongDependencyNode(
        ref: 'main:org.deepin.base/25.2/x86_64',
        kind: 'base',
        children: [
          LinglongDependencyNode(
            ref: 'main:org.deepin.runtime/25.2/x86_64',
            kind: 'runtime',
            children: [
              LinglongDependencyNode(ref: appRef, kind: 'app', children: []),
            ],
          ),
        ],
      ),
    ];
  }
}

/// 复用正式本地化与Provider，只替换只读仓储。
Widget _app(
  _Repository repository, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Key? captureKey,
}) => ProviderScope(
  overrides: [
    linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
    linglongCliCapabilitiesProvider.overrideWithValue(
      LinglongCliCapabilities.fromVersion('1.14.0'),
    ),
  ],
  child: MaterialApp(
    locale: locale,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    theme:
        (brightness == Brightness.light
                ? AppTheme.lightTheme
                : AppTheme.darkTheme)
            .copyWith(
              textTheme:
                  (brightness == Brightness.light
                          ? AppTheme.lightTheme
                          : AppTheme.darkTheme)
                      .textTheme
                      .apply(fontFamily: 'AnalysisTest'),
            ),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: RepaintBoundary(
      key: captureKey,
      child: const Scaffold(
        body: LinglongAppAnalysisDialog(
          installedApps: [
            InstalledApp(
              appId: 'demo',
              name: 'Demo',
              version: '1',
              channel: 'main',
              arch: 'x86_64',
            ),
            InstalledApp(
              appId: 'demo',
              name: 'Demo',
              version: '2',
              channel: 'main',
              arch: 'x86_64',
            ),
          ],
        ),
      ),
    ),
  ),
);

/// 可选视觉验收仅写 /tmp，普通测试不依赖开发机字体或截图目录。
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (Platform.environment['LL_STORE_ANALYSIS_CAPTURE'] != '1') return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// 依赖查询必须使用本地完整身份，不猜测缺失架构或渠道。
void main() {
  test('已安装完整身份生成 reference', () {
    const app = InstalledApp(
      appId: 'demo',
      name: 'Demo',
      version: '1',
      channel: 'main',
      arch: 'x86_64',
    );
    expect(installedAnalysisReference(app), 'main:demo/1/x86_64');
  });
  test('缺失字段使用已有版本而不猜测架构渠道', () {
    const app = InstalledApp(appId: 'demo', name: 'Demo', version: '1');
    expect(installedAnalysisReference(app), 'demo/1');
  });
  testWidgets('多版本依赖查询只使用所选本地身份且保留上游树', (tester) async {
    final repository = _Repository();
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();
    expect(repository.references, isEmpty);
    await tester.tap(find.text("Applications' environments"));
    await tester.pumpAndSettle();
    expect(repository.references, ['main:demo/1/x86_64']);
    expect(find.text('base'), findsOneWidget);
    expect(find.text('runtime'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    await tester.tap(find.byType(AppAnchoredMenuButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main:demo/2/x86_64'));
    await tester.pumpAndSettle();
    expect(repository.references.last, 'main:demo/2/x86_64');
    expect(tester.takeException(), isNull);
  });
  testWidgets('浅色与窄窗口RTL布局无溢出', (tester) async {
    if (Platform.environment['LL_STORE_ANALYSIS_CAPTURE'] == '1') {
      await tester.runAsync(() async {
        final bytes = await File(
          '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        ).readAsBytes();
        await (FontLoader(
          'AnalysisTest',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        final icons = await File(
          '/home/han/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons)))).load();
      });
    }
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_Repository(), captureKey: key));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'll-cli-analysis-light');
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(const Size(420, 680));
    final rtlKey = GlobalKey();
    await tester.pumpWidget(
      _app(
        _Repository(),
        locale: const Locale('ar'),
        brightness: Brightness.dark,
        captureKey: rtlKey,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, rtlKey, 'll-cli-analysis-rtl-dark');
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(const Size(420, 520));
    final scaledKey = GlobalKey();
    await tester.pumpWidget(
      _app(
        _Repository(),
        locale: const Locale('ar'),
        brightness: Brightness.dark,
        textScale: 1.5,
        captureKey: scaledKey,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 短窗口保持正文可滚动访问，不通过压缩字体隐藏占用信息。
    await tester.scrollUntilVisible(
      find.text('Example application with a long descriptive name'),
      80,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Example application with a long descriptive name'),
      findsOneWidget,
    );
    await _capture(tester, scaledKey, 'll-cli-analysis-rtl-large-text');
  });
}
