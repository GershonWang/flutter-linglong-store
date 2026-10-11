/// 验证新设置入口只对新版可见，并保持一次提交期间交互稳定。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/application/providers/setting_provider.dart';
import 'package:linglong_store/core/i18n/l10n/app_localizations.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/presentation/pages/setting/widgets/automatic_dependency_cleanup_tile.dart';

/// 无 IO 的界面状态替身，真实偏好持久化另在 Provider 用例验证。
class _MemorySetting extends Setting {
  @override
  SettingState build() => const SettingState();

  @override
  Future<void> setAutoPruneDependencies(bool value) async {
    state = state.copyWith(autoPruneDependencies: value);
  }
}

/// 延迟持久化事务，验证重复输入与失败不会污染事实状态。
class _ControlledSetting extends Setting {
  /// 测试手动完成事务而非依赖时间延迟。
  _ControlledSetting(this.completion);

  /// 当前提交的可控结果。
  final Completer<void> completion;

  /// 同一事务只允许提交一次。
  int calls = 0;
  @override
  SettingState build() => const SettingState();
  @override
  Future<void> setAutoPruneDependencies(bool value) async {
    calls++;
    await completion.future;
    state = state.copyWith(autoPruneDependencies: value);
  }
}

/// 使用真实本地化与设置组件，验证隐藏和可操作行为。
void main() {
  testWidgets('低版本不显示自动清理设置', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linglongCliCapabilitiesProvider.overrideWithValue(
            const LinglongCliCapabilities(),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AutomaticDependencyCleanupTile()),
        ),
      ),
    );
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('新版默认开启并可关闭', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linglongCliCapabilitiesProvider.overrideWithValue(
            LinglongCliCapabilities.fromVersion('1.14.0'),
          ),
          settingProvider.overrideWith(_MemorySetting.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AutomaticDependencyCleanupTile()),
        ),
      ),
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('保存期间禁用重复点击，失败后保留原值', (tester) async {
    final completion = Completer<void>();
    final setting = _ControlledSetting(completion);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linglongCliCapabilitiesProvider.overrideWithValue(
            LinglongCliCapabilities.fromVersion('1.14.0'),
          ),
          settingProvider.overrideWith(() => setting),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AutomaticDependencyCleanupTile()),
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    await tester.tap(find.byType(Switch));
    expect(setting.calls, 1);
    completion.completeError(StateError('storage unavailable'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 6));
  });
}
