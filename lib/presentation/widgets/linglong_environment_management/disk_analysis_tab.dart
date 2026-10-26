/// 按需呈现空间快照，搜索排序只作用于内存模块列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/providers/linglong_app_analysis_provider.dart';
import '../../../core/accessibility/accessibility.dart';
import '../../../core/i18n/l10n/app_localizations.dart';
import '../../../core/utils/format_utils.dart';
import '../../../domain/models/installed_app.dart';
import '../../../domain/models/linglong_app_analysis.dart';
import '../app_anchored_menu.dart';

/// 明确接收可见状态，TabBarView 邻页预创建也不会触发扫描。
class DiskAnalysisTab extends ConsumerStatefulWidget {
  /// 可选本地身份用于应用详情，不能用远端当前版本替代。
  const DiskAnalysisTab({required this.active, this.installedApp, super.key});

  /// 只有当前选中的页签允许发起读取。
  final bool active;

  /// 无架构统计时保留所有匹配模块，不冒充精确架构占用。
  final InstalledApp? installedApp;
  @override
  ConsumerState<DiskAnalysisTab> createState() => _DiskAnalysisTabState();
}

/// 只保存展示筛选，业务快照统一由 Provider 管理。
class _DiskAnalysisTabState extends ConsumerState<DiskAnalysisTab> {
  /// 原始快照变化后重算，避免 build 中排序。
  LinglongDiskUsage? _snapshot;

  /// 已经筛选排序的轻量列表。
  List<LinglongModuleUsage> _visible = [];

  /// 用户筛选和占用维度不触发重新扫描。
  String _query = '', _sort = 'actual';
  @override
  void initState() {
    super.initState();
    _snapshot = ref.read(linglongDiskAnalysisProvider).data;
    _filter();
    ref.listenManual(linglongDiskAnalysisProvider, (previous, next) {
      if (previous?.data != next.data) {
        _snapshot = next.data;
        if (mounted) setState(_filter);
      }
    });
    _loadIfActive();
  }

  @override
  void didUpdateWidget(DiskAnalysisTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.installedApp != widget.installedApp) _filter();
    if (!oldWidget.active && widget.active) _loadIfActive();
  }

  /// 等待布局结束，避免正在构建的 Provider 子树内更新状态。
  void _loadIfActive() {
    if (!widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        ref.read(linglongDiskAnalysisProvider.notifier).load();
      }
    });
  }

  /// 查询、身份与排序在事件边界计算，长列表渲染保持轻量。
  void _filter() {
    final app = widget.installedApp;
    final query = _query.toLowerCase();
    _visible = (_snapshot?.modules ?? const <LinglongModuleUsage>[]).where((
      module,
    ) {
      if (app != null &&
          (module.id != app.appId ||
              module.version != app.version ||
              (app.channel != null && module.channel != app.channel))) {
        return false;
      }
      return query.isEmpty ||
          module.id.toLowerCase().contains(query) ||
          module.name.toLowerCase().contains(query);
    }).toList();
    _visible.sort(
      (a, b) =>
          _sort == 'id' ? a.id.compareTo(b.id) : _size(b).compareTo(_size(a)),
    );
  }

  /// 上游四维各自独立，不绘制可相加的堆叠统计。
  int _size(LinglongModuleUsage module) => switch (_sort) {
    'exclusive' => module.exclusiveSize,
    'shared' => module.sharedSize,
    'logical' => module.logicalSize,
    _ => module.actualSize,
  };
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(linglongDiskAnalysisProvider);
    final l10n = AppLocalizations.of(context)!;
    final usage = state.data;
    final dimensions = {
      'actual': l10n.analysisActual,
      'exclusive': l10n.analysisExclusive,
      'shared': l10n.analysisShared,
      'logical': l10n.analysisLogical,
      'id': l10n.packageName,
    };
    return ExcludeFocus(
      excluding: !widget.active,
      child: Semantics(
        label: l10n.a11yAnalysisArea,
        // 标题和筛选随同模块滚动，短窗口与大字体不会挤出负高度列表。
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.analysisSpace,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      A11yIconButton(
                        icon: const Icon(Icons.refresh),
                        semanticsLabel: l10n.a11yAnalysisRefresh,
                        tooltip: l10n.refresh,
                        enabled: !state.isLoading && widget.active,
                        onTap: () => ref
                            .read(linglongDiskAnalysisProvider.notifier)
                            .load(force: true),
                      ),
                    ],
                  ),
                  if (usage != null && widget.installedApp == null)
                    Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: [
                        AnalysisMetric(
                          label: l10n.analysisRepository,
                          bytes: usage.repositoryRealSize,
                        ),
                        AnalysisMetric(
                          label: l10n.analysisModulesTotal,
                          bytes: usage.calculatedActualSize,
                        ),
                      ],
                    ),
                  if (state.isLoading)
                    Semantics(
                      label: l10n.loading,
                      child: const LinearProgressIndicator(),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.analysisAllocationNotice,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (state.error != null)
                    AnalysisErrorPanel(
                      error: state.error!,
                      onRetry: () => ref
                          .read(linglongDiskAnalysisProvider.notifier)
                          .load(force: true),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: l10n.analysisSearch,
                            isDense: true,
                            prefixIcon: const ExcludeSemantics(
                              child: Icon(Icons.search),
                            ),
                          ),
                          onChanged: (value) => setState(() {
                            _query = value;
                            _filter();
                          }),
                        ),
                      ),
                      AppAnchoredMenuButton<String>(
                        icon: Icons.sort,
                        tooltip: '${l10n.analysisSort}: ${dimensions[_sort]}',
                        semanticsLabel: l10n.a11yAnalysisSort,
                        entries: [
                          for (final entry in dimensions.entries)
                            AppAnchoredMenuItem(
                              value: entry.key,
                              label: entry.value,
                              selected: _sort == entry.key,
                            ),
                        ],
                        onSelected: (value) => setState(() {
                          _sort = value;
                          _filter();
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            if (_visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    state.isLoading && usage == null
                        ? l10n.loading
                        : usage == null || usage.modules.isEmpty
                        ? l10n.analysisEmpty
                        : l10n.analysisNoMatches,
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: _visible.length,
                itemBuilder: (context, index) {
                  final module = _visible[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          module.name.isEmpty ? module.id : module.name,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        SelectableText(
                          '${module.channel}:${module.id}/${module.version} · ${module.module}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 20,
                          runSpacing: 6,
                          children: [
                            AnalysisMetric(
                              label: l10n.analysisActual,
                              bytes: module.actualSize,
                            ),
                            AnalysisMetric(
                              label: l10n.analysisExclusive,
                              bytes: module.exclusiveSize,
                            ),
                            AnalysisMetric(
                              label: l10n.analysisShared,
                              bytes: module.sharedSize,
                            ),
                            AnalysisMetric(
                              label: l10n.analysisLogical,
                              bytes: module.logicalSize,
                            ),
                          ],
                        ),
                        const Divider(),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 独立统计口径的紧凑数值，支持窄窗口自动换行。
class AnalysisMetric extends StatelessWidget {
  /// 单个维度不与其他维度相加。
  const AnalysisMetric({required this.label, required this.bytes, super.key});

  /// 本地化统计名称。
  final String label;

  /// 上游非负字节数。
  final int bytes;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(
        FormatUtils.formatFileSize(bytes),
        style: Theme.of(context).textTheme.titleSmall,
      ),
    ],
  );
}

/// 分项错误保留完整复制入口，不遮挡另一项分析。
class AnalysisErrorPanel extends StatelessWidget {
  /// 同一诊断同时用于提示、展示与剪贴板。
  const AnalysisErrorPanel({
    required this.error,
    required this.onRetry,
    super.key,
  });

  /// 完整异常诊断。
  final String error;

  /// 显式重试，不轮询或自动循环。
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: error,
            child: Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
        A11yButton(
          semanticsLabel: l10n.a11yAnalysisCopy,
          onTap: () => Clipboard.setData(ClipboardData(text: error)),
          child: TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: error)),
            child: Text(l10n.copy),
          ),
        ),
        A11yIconButton(
          icon: const Icon(Icons.refresh),
          semanticsLabel: l10n.a11yAnalysisRetry,
          tooltip: l10n.retry,
          onTap: onRetry,
        ),
      ],
    );
  }
}
