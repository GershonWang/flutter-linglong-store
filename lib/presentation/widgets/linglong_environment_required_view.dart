/// 依赖本机玲珑环境的页面占位。
///
/// 明确区分尚未配置环境与没有已安装应用，不执行列表查询或轮询；
/// 用户仍可通过侧栏浏览商店，并随时进入统一安装及修复流程。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/accessibility/accessibility.dart';
import '../../core/config/theme.dart';
import '../../core/i18n/l10n/app_localizations.dart';
import '../helpers/linglong_environment_access.dart';

/// 供“我的应用”和“应用更新”等本机能力页复用的轻量占位。
class LinglongEnvironmentRequiredView extends ConsumerWidget {
  const LinglongEnvironmentRequiredView({super.key, this.featureName});

  /// 页面已有的国际化名称；省略时使用统一环境标题。
  final String? featureName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    void configureEnvironment() => showLinglongEnvironmentDialog(context);

    return A11yFocusScope(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ExcludeSemantics(
                  child: Icon(Icons.settings_outlined, size: 48),
                ),
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    featureName ?? l10n.envRequiredTitle,
                    textAlign: TextAlign.center,
                    style: context.appTextStyles.title3,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.envRequiredDescription,
                  textAlign: TextAlign.center,
                  style: context.appTextStyles.body.copyWith(
                    color: context.appColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                A11yButton(
                  semanticsLabel: l10n.a11yConfigureLinglongEnvironment,
                  onTap: configureEnvironment,
                  child: FilledButton.icon(
                    onPressed: configureEnvironment,
                    icon: const ExcludeSemantics(
                      child: Icon(Icons.build_outlined, size: 18),
                    ),
                    label: Text(l10n.configureLinglongEnvironment),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
