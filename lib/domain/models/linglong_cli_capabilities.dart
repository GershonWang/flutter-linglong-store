/// 玲珑新增命令的统一版本边界。
///
/// 门槛来自上游正式标签，未知版本保守关闭，避免界面暴露不能执行的操作。
library;

/// 当前 CLI 已确认可用的新能力，不以商店自身版本或发行版名称推断。
class LinglongCliCapabilities {
  /// 创建明确的能力快照，默认未知版本不开放新功能。
  const LinglongCliCapabilities({
    this.supportsDiskAnalysis = false,
    this.supportsAutoPruneControl = false,
    this.supportsMirrorRegion = false,
  });

  /// 从上游版本输出或纯版本号判断；1.14.0 预发布版不等同正式标签。
  factory LinglongCliCapabilities.fromVersion(String? output) {
    final match = _versionPattern.firstMatch(output?.trim() ?? '');
    if (match == null) return const LinglongCliCapabilities();
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) {
      return const LinglongCliCapabilities();
    }
    final beyondMinimum = major > 1 || (major == 1 && minor > 14);
    final atMinimum = major == 1 && minor == 14;
    final supported =
        beyondMinimum || (atMinimum && (patch > 0 || match.group(4) == null));
    return LinglongCliCapabilities(
      supportsDiskAnalysis: supported,
      supportsAutoPruneControl: supported,
      supportsMirrorRegion: supported,
    );
  }

  /// 环境检测文本回退复用严格识别，保留后缀，不能截断预发布版伪装正式版。
  static String? normalizeVersion(String? output) {
    final match = _versionPattern.firstMatch(output?.trim() ?? '');
    if (match == null) return null;
    return '${match.group(1)}.${match.group(2)}.${match.group(3)}'
        '${match.group(4) ?? ''}${match.group(5) ?? ''}';
  }

  /// 全量空间扫描和应用依赖关系自 1.14.0 正式版提供。
  final bool supportsDiskAnalysis;

  /// 三类包操作的未使用依赖清理控制自 1.14.0 提供。
  final bool supportsAutoPruneControl;

  /// 已有镜像开关的地区参数自 1.14.0 提供。
  final bool supportsMirrorRegion;

  /// 只接受已知 CLI 前缀和完整三段版本，避免把其他诊断数字当版本。
  static final RegExp _versionPattern = RegExp(
    r'^(?:(?:linyaps CLI version|linglong CLI version|ll-cli(?: version)?)\s+)?'
    r'(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$',
  );
}
