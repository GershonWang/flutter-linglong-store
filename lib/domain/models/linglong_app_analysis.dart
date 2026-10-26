/// 描述本地模块占用与原始依赖树，避免把分摊值解释为卸载可释放空间。
library;

/// 已安装模块统计；CLI 未提供架构字段，不推断架构归属。
class LinglongModuleUsage {
  /// 保留上游模块身份及四种独立口径。
  const LinglongModuleUsage({
    required this.id,
    required this.name,
    required this.version,
    required this.channel,
    required this.module,
    required this.exclusiveSize,
    required this.sharedSize,
    required this.logicalSize,
    required this.actualSize,
  });

  /// 包标识、名称、版本、渠道与模块组成上游返回的身份。
  final String id, name, version, channel, module;

  /// 独占、共享、逻辑与共享块分摊后的估算字节数。
  final int exclusiveSize, sharedSize, logicalSize, actualSize;
}

/// 全局统计直接采用上游去重总量，不能累加模块分摊值替代。
class LinglongDiskUsage {
  /// 创建不可变快照；仓库占用与模块占用分别保留。
  LinglongDiskUsage({
    required List<LinglongModuleUsage> modules,
    required this.calculatedExclusiveSize,
    required this.calculatedSharedSize,
    required this.calculatedLogicalSize,
    required this.calculatedActualSize,
    required this.repositoryRealSize,
  }) : modules = List.unmodifiable(modules);

  /// 包括应用、基础环境和运行时的全部未删除模块。
  final List<LinglongModuleUsage> modules;

  /// 全局逻辑统计的三个维度。
  final int calculatedExclusiveSize,
      calculatedSharedSize,
      calculatedLogicalSize;

  /// 已安装模块去重后的实际总量与仓库扫描总量。
  final int calculatedActualSize, repositoryRealSize;
}

/// 保留 base → runtime → app 的上游方向及扩展节点。
class LinglongDependencyNode {
  /// 不重排依赖方向，应用节点的 children 不能视为基础依赖。
  LinglongDependencyNode({
    required this.ref,
    required this.kind,
    required List<LinglongDependencyNode> children,
  }) : children = List.unmodifiable(children);

  /// CLI 输出的完整本地 reference。
  final String ref;

  /// 上游节点角色，不限制扩展类型。
  final String kind;

  /// 原始下游节点。
  final List<LinglongDependencyNode> children;
}
