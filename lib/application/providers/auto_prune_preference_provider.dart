/// 合并用户清理偏好与 CLI 能力，供任务入队和统一卸载入口读取快照。
///
/// 旧版不下发新旗标，保留偏好以便升级 CLI 后继续使用。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'linglong_cli_capabilities_provider.dart';
import 'setting_provider.dart';

/// 无能力时直接返回 false，不触发额外设置加载或命令探测。
final noAutoPrunePreferenceProvider = Provider<bool>((ref) {
  if (!ref.watch(linglongCliCapabilitiesProvider).supportsAutoPruneControl) {
    return false;
  }
  return !ref.watch(
    settingProvider.select((state) => state.autoPruneDependencies),
  );
});
