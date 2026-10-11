/// 本地只读分析端口，与安装和授权副作用隔离。
library;

import '../models/linglong_app_analysis.dart';

/// 按需读取仓库统计与已安装身份的环境树。
abstract interface class LinglongAppAnalysisRepository {
  /// 扫描全部模块，不支持以商店元数据过滤扫描。
  Future<LinglongDiskUsage> analyzeSize();

  /// 查询精确本地 reference，保留原始依赖层级。
  Future<List<LinglongDependencyNode>> analyzeDepends(String appRef);
}
