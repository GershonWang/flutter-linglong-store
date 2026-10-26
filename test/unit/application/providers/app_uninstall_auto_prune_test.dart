/// 验证全部卸载入口在统一服务组合根下应用相同的能力与清理偏好。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:linglong_store/application/providers/app_collection_sync_provider.dart';
import 'package:linglong_store/application/providers/app_uninstall_provider.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/application/providers/setting_provider.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/domain/models/app_operation_target_snapshot.dart';
import 'package:linglong_store/domain/models/installed_app.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';

import '../../../mocks/mock_classes.mocks.dart';

void main() {
  setUpAll(AppLogger.init);

  test('关闭清理偏好仅对受支持 CLI 下发，精准和整体卸载共用策略', () async {
    for (final version in ['1.14.0', '1.13.0', 'unknown']) {
      final repository = MockLinglongCliRepository();
      when(
        repository.uninstallApp(any, any, noAutoPrune: anyNamed('noAutoPrune')),
      ).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          linglongCliRepositoryProvider.overrideWithValue(repository),
          linglongCliCapabilitiesProvider.overrideWithValue(
            LinglongCliCapabilities.fromVersion(version),
          ),
          settingProvider.overrideWith(_PreserveDependencies.new),
          appCollectionSyncServiceProvider.overrideWith(_NoExternalSync.new),
        ],
      );
      addTearDown(container.dispose);
      const app = InstalledApp(appId: 'org.demo', name: 'demo', version: '1.0');
      final service = container.read(appUninstallServiceProvider);
      await service.executeUninstall(app);
      await service.executeUninstall(app, includeVersion: false);
      final expected = version == '1.14.0';
      verify(
        repository.uninstallApp('org.demo', '1.0', noAutoPrune: expected),
      ).called(1);
      verify(
        repository.uninstallApp('org.demo', null, noAutoPrune: expected),
      ).called(1);
    }
  });
}

/// 不做真实持久化，验证组合根仍读取唯一设置来源。
class _PreserveDependencies extends Setting {
  @override
  SettingState build() => const SettingState(autoPruneDependencies: false);
}

/// 只屏蔽成功后的外部集合读取，不替换卸载服务本身。
class _NoExternalSync extends AppCollectionSyncService {
  /// 保持组合根签名，以便保留真实服务参数传递。
  const _NoExternalSync(super.ref);
  @override
  Future<void> syncAfterSuccessfulOperation({
    List<AppOperationTargetSnapshot> updateTargets = const [],
  }) async {}
}
