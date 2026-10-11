/// 以真实已安装版本展示空间分摊与上游环境树。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/providers/linglong_app_analysis_provider.dart';
import '../../core/accessibility/accessibility.dart';
import '../../core/i18n/l10n/app_localizations.dart';
import '../../domain/models/installed_app.dart';
import '../../domain/models/linglong_app_analysis.dart';
import 'app_anchored_menu.dart';
import 'linglong_environment_management/disk_analysis_tab.dart';

/// 不猜测本地缺失字段；降级查询仍固定已安装版本，歧义由 CLI 报错。
String installedAnalysisReference(InstalledApp app) {
  final channel = app.channel;
  final arch = app.arch;
  return '${channel == null || channel.isEmpty ? '' : '$channel:'}${app.appId}/${app.version}${arch == null || arch.isEmpty ? '' : '/$arch'}';
}

/// 入口只接受本地列表，远端详情模型不能替代安装身份。
Future<void> showLinglongAppAnalysisDialog(
  BuildContext context,
  List<InstalledApp> installedApps,
) => showDialog<void>(
  context: context,
  builder: (_) => LinglongAppAnalysisDialog(installedApps: installedApps),
);

/// 多个本地版本可切换，空间和依赖分别加载并呈现诊断。
class LinglongAppAnalysisDialog extends ConsumerStatefulWidget {
  /// 调用方必须保证至少有一个真实已安装版本。
  const LinglongAppAnalysisDialog({required this.installedApps, super.key});

  /// 真实本地身份列表，包含版本和架构。
  final List<InstalledApp> installedApps;
  @override
  ConsumerState<LinglongAppAnalysisDialog> createState() =>
      _LinglongAppAnalysisDialogState();
}

/// 页签是局部状态，缓存快照仍由统一 Provider 所有。
class _LinglongAppAnalysisDialogState
    extends ConsumerState<LinglongAppAnalysisDialog> {
  /// 默认展示空间，依赖仅切换后读取。
  int _tab = 0, _selected = 0;

  /// 选择变更后仅对可见依赖页发起查询。
  void _loadDependencies() {
    if (_tab != 1) return;
    ref
        .read(
          linglongAppDependenciesProvider(
            installedAnalysisReference(widget.installedApps[_selected]),
          ).notifier,
        )
        .load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 调用入口只传非空本地列表；开发期在使用边界验证此约束。
    assert(widget.installedApps.isNotEmpty);
    final app = widget.installedApps[_selected];
    return A11yFocusScope(
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(l10n.analysisApp),
        content: SizedBox(
          width: 680,
          height: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SelectableText(installedAnalysisReference(app)),
                  ),
                  if (widget.installedApps.length > 1)
                    AppAnchoredMenuButton<int>(
                      icon: Icons.unfold_more,
                      tooltip: l10n.analysisInstalledVersion,
                      semanticsLabel: l10n.a11yAnalysisVersion,
                      entries: [
                        for (
                          var index = 0;
                          index < widget.installedApps.length;
                          index++
                        )
                          AppAnchoredMenuItem(
                            value: index,
                            label: installedAnalysisReference(
                              widget.installedApps[index],
                            ),
                            selected: index == _selected,
                          ),
                      ],
                      onSelected: (index) {
                        setState(() => _selected = index);
                        _loadDependencies();
                      },
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: A11yTab(
                      label: l10n.analysisSpace,
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                      // 视觉选中状态与无障碍 selected 同步，避免两个页签看起来相同。
                      child: Text(
                        l10n.analysisSpace,
                        style: TextStyle(
                          color: _tab == 0
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          fontWeight: _tab == 0
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: A11yTab(
                      label: l10n.analysisDependencies,
                      selected: _tab == 1,
                      onTap: () {
                        setState(() => _tab = 1);
                        _loadDependencies();
                      },
                      child: Text(
                        l10n.analysisDependencies,
                        style: TextStyle(
                          color: _tab == 1
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          fontWeight: _tab == 1
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: _tab == 0
                    ? DiskAnalysisTab(active: true, installedApp: app)
                    : _DependencyAnalysisView(
                        appRef: installedAnalysisReference(app),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          A11yButton(
            semanticsLabel: l10n.a11yClose,
            onTap: () => Navigator.of(context).pop(),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.close),
            ),
          ),
        ],
      ),
    );
  }
}

/// 树展平在快照变更时完成，builder 只读取已准备的行。
class _DependencyAnalysisView extends ConsumerStatefulWidget {
  /// 完整或上游可解析的本地 reference，始终保留已安装版本。
  const _DependencyAnalysisView({required this.appRef});

  /// 查询键与当前选择身份一致。
  final String appRef;
  @override
  ConsumerState<_DependencyAnalysisView> createState() =>
      _DependencyAnalysisViewState();
}

/// 保留原始树方向，避免把 app children 误标为运行时。
class _DependencyAnalysisViewState
    extends ConsumerState<_DependencyAnalysisView> {
  /// 已展平的行及层级，不在 build 中递归。
  List<({LinglongDependencyNode node, int depth})> _rows = [];

  /// 切换版本后替换订阅，关闭面板释放 UI 监听。
  ProviderSubscription<LinglongAnalysisState<List<LinglongDependencyNode>>>?
  _subscription;
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_DependencyAnalysisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appRef != widget.appRef) _subscribe();
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

  /// 每个快照只展平一次，保留根节点与所有扩展节点。
  void _flatten(List<LinglongDependencyNode>? nodes) {
    _rows = [];
    void visit(LinglongDependencyNode node, int depth) {
      _rows.add((node: node, depth: depth));
      for (final child in node.children) {
        visit(child, depth + 1);
      }
    }

    for (final node in nodes ?? const <LinglongDependencyNode>[]) {
      visit(node, 0);
    }
  }

  /// UI 订阅不触发仓库命令，只有页签动作调用 load。
  void _subscribe() {
    _subscription?.close();
    final provider = linglongAppDependenciesProvider(widget.appRef);
    _flatten(ref.read(provider).data);
    _subscription = ref.listenManual(provider, (previous, next) {
      if (previous?.data != next.data && mounted) {
        setState(() => _flatten(next.data));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(linglongAppDependenciesProvider(widget.appRef));
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.a11yAnalysisArea,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.analysisDependencies)),
              A11yIconButton(
                icon: const Icon(Icons.refresh),
                semanticsLabel: l10n.a11yAnalysisRefresh,
                tooltip: l10n.refresh,
                enabled: !state.isLoading,
                onTap: () => ref
                    .read(
                      linglongAppDependenciesProvider(widget.appRef).notifier,
                    )
                    .load(force: true),
              ),
            ],
          ),
          if (state.isLoading)
            Semantics(
              label: l10n.loading,
              child: const LinearProgressIndicator(),
            ),
          if (state.error != null)
            AnalysisErrorPanel(
              error: state.error!,
              onRetry: () => ref
                  .read(linglongAppDependenciesProvider(widget.appRef).notifier)
                  .load(force: true),
            ),
          Expanded(
            child: _rows.isEmpty
                ? Center(
                    child: Text(
                      state.isLoading ? l10n.loading : l10n.analysisEmpty,
                    ),
                  )
                : ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (_, index) {
                      final row = _rows[index];
                      // 深树缩进设上限，避免窄窗口被缩进吃掉正文空间。
                      return Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: row.depth.clamp(0, 5) * 14.0,
                          top: 8,
                          bottom: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.node.kind,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            SelectableText(row.node.ref),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
