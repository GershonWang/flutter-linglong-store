/// 依赖自动清理设置入口。
///
/// 仅支持该参数的 CLI 展示此项，保存成功后才更新开关，保证排队任务策略可预测。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/providers/linglong_cli_capabilities_provider.dart';
import '../../../../application/providers/setting_provider.dart';
import '../../../../core/accessibility/a11y_semantics.dart';
import '../../../../core/i18n/l10n/app_localizations.dart';
import '../../../../core/utils/app_notification_helpers.dart';

/// 与设置状态共用唯一事实来源，不维护第二份业务开关值。
class AutomaticDependencyCleanupTile extends ConsumerStatefulWidget {
  /// 独立入口便于验证旧版本隐藏及保存失败场景。
  const AutomaticDependencyCleanupTile({super.key});

  @override
  ConsumerState<AutomaticDependencyCleanupTile> createState() =>
      _AutomaticDependencyCleanupTileState();
}

/// 仅保存短暂交互状态，防止连续点击覆盖尚未完成的持久化事务。
class _AutomaticDependencyCleanupTileState
    extends ConsumerState<AutomaticDependencyCleanupTile> {
  /// 保存期间禁用输入，业务值仍由 Provider 提供。
  bool _saving = false;

  /// 持久化失败保留旧状态，并沿用项目统一错误反馈。
  Future<void> _save(bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(settingProvider.notifier).setAutoPruneDependencies(value);
    } catch (error) {
      if (mounted) {
        showAppError(
          context,
          AppLocalizations.of(
            context,
          )!.envResultUnexpectedFailure(error.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(linglongCliCapabilitiesProvider).supportsAutoPruneControl) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final value = ref.watch(
      settingProvider.select((state) => state.autoPruneDependencies),
    );
    return A11yListItem(
      semanticsLabel: l10n.a11yAutoPruneDependencies,
      enabled: !_saving,
      child: SwitchListTile(
        secondary: const ExcludeSemantics(
          child: Icon(Icons.auto_delete_outlined),
        ),
        title: Text(l10n.autoPruneDependencies),
        subtitle: Text(l10n.autoPruneDependenciesDescription),
        value: value,
        onChanged: _saving ? null : _save,
      ),
    );
  }
}
