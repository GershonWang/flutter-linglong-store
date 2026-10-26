/// 玲珑仓库管理区域。
///
/// 该文件负责仓库配置的列表和操作菜单展示，所有修改动作通过回调交给
/// 对话框交互控制器，组件自身不读取 Provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../application/providers/linglong_environment_management_provider.dart';
import '../../../core/config/theme.dart';
import '../../../core/accessibility/accessibility.dart';
import '../../../core/i18n/l10n/app_localizations.dart';
import '../../../domain/models/linglong_env_check_result.dart';
import '../app_anchored_menu.dart';
import 'environment_management_components.dart';

/// 展示仓库配置并提供仓库操作入口。
class RepositoryManagementTab extends StatelessWidget {
  /// 创建仓库管理区域。
  const RepositoryManagementTab({
    required this.state,
    required this.onAddRepository,
    required this.onUpdateRepository,
    required this.onRemoveRepository,
    required this.onSetDefaultRepository,
    required this.onSetPriority,
    required this.onSetMirror,
    this.supportsMirrorRegion = false,
    this.onSetMirrorRegion,
    this.onCustomMirrorRegion,
    super.key,
  });

  /// 当前环境管理状态。
  final LinglongEnvironmentManagementState state;

  /// 添加仓库的回调。
  final VoidCallback onAddRepository;

  /// 修改仓库地址的回调。
  final ValueChanged<LinglongRepoInfo> onUpdateRepository;

  /// 删除仓库的回调。
  final ValueChanged<LinglongRepoInfo> onRemoveRepository;

  /// 设置默认仓库的回调。
  final ValueChanged<LinglongRepoInfo> onSetDefaultRepository;

  /// 设置仓库优先级的回调。
  final ValueChanged<LinglongRepoInfo> onSetPriority;

  /// 修改仓库镜像状态的回调。
  final void Function(LinglongRepoInfo repo, {required bool enabled})
  onSetMirror;

  /// 统一版本能力只由对话框传入，旧版不创建地区控件。
  final bool supportsMirrorRegion;

  /// 选择地区会开启镜像；null 明确表示交由服务端自动选择。
  final void Function(LinglongRepoInfo repo, String? region)? onSetMirrorRegion;

  /// 自定义地区表单交由统一交互控制器管理。
  final ValueChanged<LinglongRepoInfo>? onCustomMirrorRegion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = state.repositoryConfig;
    if (config == null) {
      return EnvironmentManagementEmptyState(
        icon: Icons.hub_outlined,
        title: state.errorMessage == null
            ? l10n.envRepositoryNotLoaded
            : l10n.envResultUnexpectedFailure(state.errorMessage!),
      );
    }

    // 说明与仓库行使用同一个惰性滚动区，大字体下不会挤出负高度列表。
    return A11yFocusScope(
      child: Semantics(
        label: l10n.a11yMirrorRepositories,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.envRepositoryDefaultValue(
                            config.defaultRepo ?? l10n.envNotSet,
                          ),
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: context.appFontWeight(
                                  FontWeight.w600,
                                ),
                              ),
                        ),
                      ),
                      A11yButton(
                        enabled: !state.isBusy,
                        semanticsLabel: l10n.a11yMirrorAddRepository,
                        onTap: onAddRepository,
                        child: FilledButton.icon(
                          onPressed: state.isBusy ? null : onAddRepository,
                          icon: const ExcludeSemantics(
                            child: Icon(Icons.add, size: 18),
                          ),
                          label: Text(l10n.envAddRepository),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  EnvironmentManagementInfoPanel(
                    icon: Icons.info_outline,
                    title: AppLocalizations.of(
                      context,
                    )!.repoManagementHintTitle,
                    message: AppLocalizations.of(
                      context,
                    )!.repoManagementHintMessage,
                  ),
                  const SizedBox(height: 12),
                  if (state.errorMessage != null) ...[
                    _RepositoryDiagnostic(
                      message: state.errorMessage!,
                      isUnconfirmed: state.unconfirmedMirrorAlias != null,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
            if (config.repos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EnvironmentManagementEmptyState(
                  icon: Icons.hub_outlined,
                  title: l10n.envNoRepositories,
                ),
              )
            else
              SliverList.separated(
                itemCount: config.repos.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final repo = config.repos[index];
                  final isDefault =
                      repo.name == config.defaultRepo ||
                      repo.alias == config.defaultRepo;
                  return _RepositoryTile(
                    repo: repo,
                    isDefault: isDefault,
                    isBusy: state.isBusy,
                    onUpdateRepository: onUpdateRepository,
                    onRemoveRepository: onRemoveRepository,
                    onSetDefaultRepository: onSetDefaultRepository,
                    onSetPriority: onSetPriority,
                    onSetMirror: onSetMirror,
                    supportsMirrorRegion: supportsMirrorRegion,
                    // 回读失败时整个配置快照已过期，连续操作其他仓库也不能恢复旧值。
                    isMirrorUnconfirmed: state.unconfirmedMirrorAlias != null,
                    onSetMirrorRegion: onSetMirrorRegion,
                    onCustomMirrorRegion: onCustomMirrorRegion,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 单个仓库的确认配置与可用操作，数据只由上层快照下发。
class _RepositoryTile extends StatelessWidget {
  /// 绑定仓库身份和版本能力，不自行读取 Provider。
  const _RepositoryTile({
    required this.repo,
    required this.isDefault,
    required this.isBusy,
    required this.onUpdateRepository,
    required this.onRemoveRepository,
    required this.onSetDefaultRepository,
    required this.onSetPriority,
    required this.onSetMirror,
    required this.supportsMirrorRegion,
    required this.isMirrorUnconfirmed,
    this.onSetMirrorRegion,
    this.onCustomMirrorRegion,
  });

  final LinglongRepoInfo repo;
  final bool isDefault;
  final bool isBusy;
  final ValueChanged<LinglongRepoInfo> onUpdateRepository;
  final ValueChanged<LinglongRepoInfo> onRemoveRepository;
  final ValueChanged<LinglongRepoInfo> onSetDefaultRepository;
  final ValueChanged<LinglongRepoInfo> onSetPriority;
  final void Function(LinglongRepoInfo repo, {required bool enabled})
  onSetMirror;

  /// 是否允许展示地区选择。
  final bool supportsMirrorRegion;

  /// 已提交的配置未确认时，旧快照不能继续冒充当前状态。
  final bool isMirrorUnconfirmed;

  /// 提交明确地区或自动选择。
  final void Function(LinglongRepoInfo repo, String? region)? onSetMirrorRegion;

  /// 进入自定义代码表单。
  final ValueChanged<LinglongRepoInfo>? onCustomMirrorRegion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(
              isDefault ? Icons.star_rounded : Icons.hub_outlined,
              color: isDefault
                  ? AppColors.warning
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        linglongRepositoryDisplayName(repo),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: context.appFontWeight(FontWeight.w600),
                        ),
                      ),
                    ),
                    if (isDefault) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadius.full),
                        ),
                        child: Text(
                          l10n.envDefaultBadge,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: AppColors.warning,
                                fontWeight: context.appFontWeight(
                                  FontWeight.w600,
                                ),
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  repo.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.envRepositoryDetails(
                    repo.name,
                    repo.priority ?? l10n.envNotSet,
                  ),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (supportsMirrorRegion) ...[
                  const SizedBox(height: 8),
                  _RepositoryMirrorControls(
                    repo: repo,
                    isBusy: isBusy,
                    isUnconfirmed: isMirrorUnconfirmed,
                    onSetMirror: onSetMirror,
                    onSetRegion: onSetMirrorRegion,
                    onCustomRegion: onCustomMirrorRegion,
                  ),
                ],
              ],
            ),
          ),
          AppAnchoredMenuButton<_RepositoryAction>(
            enabled: !isBusy,
            tooltip: l10n.envRepositoryActions,
            semanticsLabel: l10n.a11yMirrorActions,
            onSelected: (action) {
              switch (action) {
                case _RepositoryAction.editUrl:
                  onUpdateRepository(repo);
                case _RepositoryAction.setDefault:
                  onSetDefaultRepository(repo);
                case _RepositoryAction.setPriority:
                  onSetPriority(repo);
                case _RepositoryAction.enableMirror:
                  onSetMirror(repo, enabled: true);
                case _RepositoryAction.disableMirror:
                  onSetMirror(repo, enabled: false);
                case _RepositoryAction.remove:
                  onRemoveRepository(repo);
              }
            },
            entries: [
              AppAnchoredMenuItem(
                value: _RepositoryAction.editUrl,
                label: l10n.envEditAddress,
              ),
              AppAnchoredMenuItem(
                value: _RepositoryAction.setDefault,
                label: l10n.envSetDefault,
              ),
              AppAnchoredMenuItem(
                value: _RepositoryAction.setPriority,
                label: l10n.envSetPriority,
              ),
              if (!supportsMirrorRegion)
                AppAnchoredMenuItem(
                  value: _RepositoryAction.enableMirror,
                  label: l10n.envEnableMirror,
                  enabled: !isMirrorUnconfirmed,
                ),
              if (!supportsMirrorRegion)
                AppAnchoredMenuItem(
                  value: _RepositoryAction.disableMirror,
                  label: l10n.envDisableMirror,
                  enabled: !isMirrorUnconfirmed,
                ),
              const AppAnchoredMenuDivider(),
              AppAnchoredMenuItem(
                value: _RepositoryAction.remove,
                label: l10n.envRemoveRepositoryTitle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 开关与地区菜单共用确认快照，Wrap 让窄窗口和大字体自然换行。
class _RepositoryMirrorControls extends StatelessWidget {
  /// 绑定无副作用展示属性和业务动作。
  const _RepositoryMirrorControls({
    required this.repo,
    required this.isBusy,
    required this.isUnconfirmed,
    required this.onSetMirror,
    this.onSetRegion,
    this.onCustomRegion,
  });

  /// 服务端确认的仓库快照。
  final LinglongRepoInfo repo;

  /// 配置事务期间禁用重复操作。
  final bool isBusy;

  /// 未确认状态不显示过期快照的开关值。
  final bool isUnconfirmed;

  /// 开关事件由控制器决定是否保留已存地区。
  final void Function(LinglongRepoInfo repo, {required bool enabled})
  onSetMirror;

  /// 选择地区或自动模式。
  final void Function(LinglongRepoInfo repo, String? region)? onSetRegion;

  /// 自定义代码输入入口。
  final ValueChanged<LinglongRepoInfo>? onCustomRegion;

  /// 根据确认值渲染状态，未知不是关闭。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mirrorEnabled = isUnconfirmed ? null : repo.isMirrorEnabled;
    // 文本回退不能证明缺省地区是自动，缺乏证据时不允许保留式开关。
    final regionKnown =
        !isUnconfirmed && (repo.isMirrorEnabled != null || repo.region != null);
    final name = linglongRepositoryDisplayName(repo);
    final status = switch (mirrorEnabled) {
      true => l10n.envMirrorEnabled,
      false => l10n.envMirrorDisabled,
      null => l10n.mirrorStatusUnknown,
    };
    final selectedRegion = repo.region ?? '';
    final regionLabel = switch (selectedRegion) {
      '' => l10n.mirrorRegionAuto,
      'CN' => l10n.mirrorRegionChina,
      'US' => l10n.mirrorRegionUnitedStates,
      'EU' => l10n.mirrorRegionEurope,
      _ => selectedRegion,
    };
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          toggled: mirrorEnabled,
          child: A11yButton(
            enabled: !isBusy && regionKnown,
            semanticsLabel: l10n.a11yMirrorToggle(name),
            semanticsValue: status,
            onTap: () => onSetMirror(repo, enabled: mirrorEnabled != true),
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    key: ValueKey('mirror-switch-$name'),
                    value: mirrorEnabled == true,
                    onChanged: isBusy || !regionKnown
                        ? null
                        : (enabled) => onSetMirror(repo, enabled: enabled),
                  ),
                  Flexible(
                    child: Text(
                      status,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: AppAnchoredMenu<String>(
            entries: [
              for (final entry in <String, String>{
                '': l10n.mirrorRegionAuto,
                'CN': l10n.mirrorRegionChina,
                'US': l10n.mirrorRegionUnitedStates,
                'EU': l10n.mirrorRegionEurope,
              }.entries)
                AppAnchoredMenuItem(
                  value: entry.key,
                  label: entry.value,
                  selected: regionKnown && selectedRegion == entry.key,
                ),
              const AppAnchoredMenuDivider(),
              AppAnchoredMenuItem(
                value: '__custom__',
                label: l10n.mirrorRegionCustom,
                selected:
                    regionKnown &&
                    !const ['', 'CN', 'US', 'EU'].contains(selectedRegion),
              ),
            ],
            onSelected: (value) {
              if (isBusy) return;
              if (value == '__custom__') {
                onCustomRegion?.call(repo);
              } else {
                onSetRegion?.call(repo, value.isEmpty ? null : value);
              }
            },
            builder: (context, handle) => A11yButton(
              semanticsLabel: l10n.a11yMirrorRegion(name),
              semanticsValue: !regionKnown
                  ? l10n.mirrorStatusUnknown
                  : regionLabel,
              enabled: !isBusy,
              onTap: handle.toggle,
              child: TextButton(
                key: ValueKey('mirror-region-$name'),
                focusNode: handle.focusNode,
                onPressed: isBusy ? null : handle.toggle,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.mirrorRegionTitle),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Tooltip(
                        message: !regionKnown
                            ? l10n.mirrorStatusUnknown
                            : regionLabel,
                        child: Text(
                          !regionKnown ? l10n.mirrorStatusUnknown : regionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const ExcludeSemantics(
                      child: Icon(Icons.expand_more, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 完整错误保留于 Tooltip 和复制入口，长诊断不会撑开仓库列表。
class _RepositoryDiagnostic extends StatelessWidget {
  /// 区分已提交未确认与普通命令失败。
  const _RepositoryDiagnostic({
    required this.message,
    required this.isUnconfirmed,
  });

  /// 可复制的完整诊断。
  final String message;

  /// 是否需要明确提示配置已提交但当前状态未知。
  final bool isUnconfirmed;

  /// 以本地化标签和可键盘激活的按钮呈现诊断。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.a11yMirrorDiagnostic,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isUnconfirmed)
            Text(
              l10n.mirrorConfigurationUnconfirmed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: message,
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              A11yButton(
                semanticsLabel: l10n.a11yMirrorCopyDiagnostic,
                onTap: () => Clipboard.setData(ClipboardData(text: message)),
                child: TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: message)),
                  icon: const ExcludeSemantics(
                    child: Icon(Icons.copy_outlined, size: 16),
                  ),
                  label: Text(l10n.copy),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 旧版仓库菜单继续沿用原有镜像开关动作。
enum _RepositoryAction {
  editUrl,
  setDefault,
  setPriority,
  enableMirror,
  disableMirror,
  remove,
}
