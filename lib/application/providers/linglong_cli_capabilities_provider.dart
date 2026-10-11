/// 把启动期实际检测版本转换成全应用共享的命令能力。
///
/// 不新增启动命令，页面和参数构造共用这一快照，检测未完成时隐藏新入口。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/linglong_cli_capabilities.dart';
import 'linglong_env_provider.dart';

/// 从环境检测的真实 CLI 版本派生，不用商店版本或操作系统版本兜底。
final linglongCliCapabilitiesProvider = Provider<LinglongCliCapabilities>((
  ref,
) {
  final version = ref.watch(
    linglongEnvProvider.select((state) => state.result?.llCliVersion),
  );
  return LinglongCliCapabilities.fromVersion(version);
});
