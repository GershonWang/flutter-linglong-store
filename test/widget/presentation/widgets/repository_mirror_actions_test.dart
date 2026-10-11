/// 验证镜像表单与开关沿统一交互入口执行，不改动真实仓库。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';
import 'package:linglong_store/domain/models/linglong_repository_config.dart';
import 'package:linglong_store/domain/repositories/linglong_repository_management_repository.dart';
import 'package:linglong_store/presentation/widgets/linglong_environment_management/environment_management_dialog_actions.dart';

/// 使用真实控制器和 Provider，外部边界由内存配置隔离。
void main() {
  setUpAll(AppLogger.init);

  testWidgets('自定义非法代码留在表单，修正后显式提交新地区', (tester) async {
    final repository = _MemoryRepository();
    await tester.pumpWidget(_app(repository));
    await tester.tap(find.text('custom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'CN&region=US');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(find.text(l10n.mirrorRegionInvalid), findsOneWidget);
    expect(repository.writes, isEmpty);
    await tester.enterText(find.byType(TextFormField), 'US');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(repository.writes.single, {'enabled': true, 'region': 'US'});
    expect(repository.current.region, 'US');
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新启用传回确认快照里的已保存地区', (tester) async {
    final repository = _MemoryRepository();
    await tester.pumpWidget(_app(repository));
    await tester.tap(find.text('reenable'));
    await tester.pumpAndSettle();
    expect(repository.writes.single, {'enabled': true, 'region': 'CN'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少地区证据时保留式开关不能清除可能已保存的地区', (tester) async {
    final repository = _MemoryRepository()
      ..current = const LinglongRepoInfo(
        name: 'stable',
        url: 'https://repo.example.com',
      );
    await tester.pumpWidget(_app(repository));
    await tester.tap(find.text('reenable'));
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧版本开关沿既有命令契约不传地区', (tester) async {
    final repository = _MemoryRepository();
    await tester.pumpWidget(_app(repository, version: '1.13.0'));
    await tester.tap(find.text('reenable'));
    await tester.pumpAndSettle();
    expect(repository.writes.single, {'enabled': true, 'region': null});
  });
}

/// 最小交互壳让输入、确认、反馈都通过生产控制器。
Widget _app(_MemoryRepository repository, {String version = '1.14.0'}) =>
    ProviderScope(
      overrides: [
        linglongCliCapabilitiesProvider.overrideWithValue(
          LinglongCliCapabilities.fromVersion(version),
        ),
        linglongRepositoryManagementRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) {
            final actions = LinglongEnvironmentManagementActions(ref);
            return Scaffold(
              body: Row(
                children: [
                  TextButton(
                    onPressed: () => actions.showMirrorRegionDialog(
                      context,
                      repository.current,
                    ),
                    child: const Text('custom'),
                  ),
                  TextButton(
                    onPressed: () => actions.setRepositoryMirror(
                      context,
                      repository.current,
                      enabled: true,
                    ),
                    child: const Text('reenable'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

/// 模拟上游读写副作用，关闭时保留地区，开启 null 时清除地区。
class _MemoryRepository extends Fake
    implements LinglongRepositoryManagementRepository {
  /// 初始配置已确认，适合测试关闭后重新启用。
  LinglongRepoInfo current = const LinglongRepoInfo(
    name: 'stable',
    url: 'https://repo.example.com',
    isMirrorEnabled: false,
    region: 'CN',
  );

  /// 记录真实控制器传给 Repository 的请求。
  final writes = <Map<String, Object?>>[];

  /// 返回刚写入的真实内存快照，驱动 Provider 严格回读。
  @override
  Future<LinglongRepositoryConfig> getRepositoryConfig() async =>
      LinglongRepositoryConfig(defaultRepo: 'stable', repos: [current]);

  /// 只模拟镜像用例，其他仓库用例不是本测试的调用范围。
  @override
  Future<String> setRepositoryMirror(
    String aliasOrName, {
    required bool enabled,
    String? region,
  }) async {
    writes.add({'enabled': enabled, 'region': region});
    current = current.copyWith(
      isMirrorEnabled: enabled,
      region: enabled ? region : current.region,
    );
    return '';
  }
}
