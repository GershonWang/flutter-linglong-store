/// 验证旧版不读取保留偏好，新版默认清理且持久化后正确恢复。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/auto_prune_preference_provider.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/application/providers/linux_renderer_provider.dart';
import 'package:linglong_store/application/providers/setting_provider.dart';
import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/core/platform/linux_renderer_service.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppLogger.init);

  test('低版本不会初始化设置，也不会发送保留参数', () {
    final container = ProviderContainer(
      overrides: [
        linglongCliCapabilitiesProvider.overrideWithValue(
          const LinglongCliCapabilities(),
        ),
        settingProvider.overrideWith(() => _ForbiddenSetting()),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(noAutoPrunePreferenceProvider), false);
  });

  test('新版默认开启，关闭后恢复持久化偏好', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer createContainer() => ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        linglongCliCapabilitiesProvider.overrideWithValue(
          LinglongCliCapabilities.fromVersion('1.14.0'),
        ),
        linuxRendererServiceProvider.overrideWithValue(
          LinuxRendererService(
            configFilePathOverride:
                '/tmp/ll-cli-test-nonexistent-renderer-config',
          ),
        ),
      ],
    );
    final first = createContainer();
    addTearDown(first.dispose);
    expect(first.read(noAutoPrunePreferenceProvider), false);
    await first.read(settingProvider.notifier).setAutoPruneDependencies(false);
    expect(first.read(noAutoPrunePreferenceProvider), true);
    expect(prefs.getBool('setting_auto_prune_dependencies'), false);
    final restored = createContainer();
    addTearDown(restored.dispose);
    expect(restored.read(noAutoPrunePreferenceProvider), true);
  });
}

/// 旧版能力判定必须先于设置读取，避免产生任何额外初始化副作用。
class _ForbiddenSetting extends Setting {
  @override
  SettingState build() => throw StateError('旧版本不应读取设置');
}
