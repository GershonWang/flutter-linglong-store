/// 复用现有 CLI 执行边界，后台解析大体积空间扫描结果。
library;

import 'dart:convert';
import 'dart:isolate';
import '../../core/platform/cli_executor.dart';
import '../../domain/models/linglong_app_analysis.dart';
import '../../domain/repositories/linglong_app_analysis_repository.dart';

/// 可注入执行边界，便于验证只读 argv 且不触碰开发机安装状态。
typedef LinglongAnalysisCommand = Future<CliOutput> Function(List<String> args);

/// 只读分析仓储，不使用特权 helper 或额外 Shell。
class LinglongAppAnalysisRepositoryImpl
    implements LinglongAppAnalysisRepository {
  /// 生产复用统一执行器；空间遍历允许使用已有默认超时。
  LinglongAppAnalysisRepositoryImpl({LinglongAnalysisCommand? execute})
    : _execute = execute ?? _executeCommand;

  /// 同一实例的只读执行端口。
  final LinglongAnalysisCommand _execute;

  /// 统一默认命令超时适用于仓库遍历。
  static Future<CliOutput> _executeCommand(List<String> args) =>
      CliExecutor.execute(args);

  /// 保留完整失败诊断，供界面复制。
  Future<String> _read(List<String> args) async {
    final output = await _execute(args);
    if (!output.success) {
      // analyze 的错误对象写入 stdout；stderr 警告不能遮蔽真正的失败原因。
      final diagnostic = [
        'll-cli (${output.exitCode})',
        if (output.stdout.isNotEmpty) 'stdout:\n${output.stdout}',
        if (output.stderr.isNotEmpty) 'stderr:\n${output.stderr}',
      ].join('\n');
      throw StateError(diagnostic);
    }
    return output.stdout;
  }

  @override
  Future<LinglongDiskUsage> analyzeSize() async {
    final raw = await _read(['--json', 'analyze', 'size']);
    return Isolate.run(() => parseLinglongDiskUsage(raw));
  }

  @override
  Future<List<LinglongDependencyNode>> analyzeDepends(String appRef) async {
    if (appRef.trim().isEmpty) throw ArgumentError.value(appRef, 'appRef');
    final raw = await _read(['--json', 'analyze', 'depends', appRef]);
    return Isolate.run(() => parseLinglongDependencies(raw));
  }
}

/// 严格拒绝错误根对象，防止失败响应成为有效空快照。
Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected analysis object');
  }
  return value;
}

/// CLI 字节数只能是非负整数；缺字段不补零。
int _bytes(Map<String, dynamic> value, String key) {
  final number = value[key];
  if (number is! int || number < 0) {
    throw FormatException('Invalid byte count: $key');
  }
  return number;
}

/// 身份字段必须存在，不创建未知的本地身份。
String _text(Map<String, dynamic> value, String key) {
  final text = value[key];
  if (text is! String) throw FormatException('Invalid analysis field: $key');
  return text;
}

/// 列表缺失与空列表不同，前者说明响应不符合契约。
List<dynamic> _list(dynamic value) {
  if (value is! List) throw const FormatException('Expected analysis list');
  return value;
}

/// 使用真实上游字段读取四维模块统计和独立全局总量。
LinglongDiskUsage parseLinglongDiskUsage(String raw) {
  final root = _object(jsonDecode(raw));
  final logical = _object(root['calculatedLogicalSize']);
  final modules = _list(root['modules']).map((item) {
    final value = _object(item);
    return LinglongModuleUsage(
      id: _text(value, 'id'),
      name: _text(value, 'name'),
      version: _text(value, 'version'),
      channel: _text(value, 'channel'),
      module: _text(value, 'module'),
      exclusiveSize: _bytes(value, 'exclusiveSize'),
      sharedSize: _bytes(value, 'sharedSize'),
      logicalSize: _bytes(value, 'logicalSize'),
      actualSize: _bytes(value, 'actualSize'),
    );
  }).toList();
  return LinglongDiskUsage(
    modules: modules,
    calculatedExclusiveSize: _bytes(logical, 'exclusiveSize'),
    calculatedSharedSize: _bytes(logical, 'sharedSize'),
    calculatedLogicalSize: _bytes(logical, 'logicalSize'),
    calculatedActualSize: _bytes(root, 'calculatedActualSize'),
    repositoryRealSize: _bytes(root, 'repositoryRealSize'),
  );
}

/// 保留根到应用的依赖方向，包含扩展节点。
List<LinglongDependencyNode> parseLinglongDependencies(String raw) =>
    _list(jsonDecode(raw)).map(_node).toList();

/// 递归转换仅在后台 isolate 执行，不在 Widget build 中解析。
LinglongDependencyNode _node(dynamic item) {
  final value = _object(item);
  return LinglongDependencyNode(
    ref: _text(value, 'ref'),
    kind: _text(value, 'kind'),
    children: _list(value['children']).map(_node).toList(),
  );
}
