/// 当前进程的运行形态。
///
/// 业务定位：
///   商店有两条运行形态——常规宿主安装（DEB / RPM / AppImage / 开发态）与玲珑容器
///   形态（UAB 运行在玲珑沙箱里）。两者可用的系统能力不同，Application 与
///   Presentation 必须据此**提前降级**，而不是让用户点击后才失败。
///
/// 为什么需要这个事实：
///   容器形态下 ll-cli 经宿主透传执行（docs/60），因此"用 ll-cli 管应用"是可行的；
///   但两项特权能力按设计关闭：
///     - 免密安装要写宿主 `/etc/polkit-1/rules.d`，需要从沙箱打通 pkexec 提权通道，
///       本设计刻意不打通（docs/60 §7）；
///     - 取消安装需要宿主 ll-cli 的 PID，而桥返回的进程句柄是本地 `systemd-run`，
///       拿不到宿主进程，取消不可靠。
///   把这两点收敛成"运行形态"一个事实，避免各处各自判断环境变量。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 运行形态。
enum LinglongRuntimeForm {
  /// 常规宿主安装：ll-cli 本地直调，全部能力可用。
  hostInstalled,

  /// 玲珑容器形态：ll-cli 经宿主透传，特权能力按设计关闭。
  linglongContainer,
}

/// 当前运行形态。
///
/// 默认按常规宿主安装处理，保证测试与非玲珑形态行为不变；生产由组合根在启动期
/// 依据宿主透传通道的探测结果覆盖。
final linglongRuntimeFormProvider = Provider<LinglongRuntimeForm>(
  (ref) => LinglongRuntimeForm.hostInstalled,
);

/// 当前形态是否允许取消安装任务。
///
/// 容器形态下取消不可靠（见文件头），因此关闭该动作——Presentation 据此把取消
/// 按钮置为不可用，而不是让用户点了没反应。
final installCancelEnabledProvider = Provider<bool>((ref) {
  return ref.watch(linglongRuntimeFormProvider) ==
      LinglongRuntimeForm.hostInstalled;
});

/// 当前形态是否支持免密安装规则。
///
/// 容器形态下写宿主 polkit 规则需要沙箱逃逸提权，本设计不提供，因此按不支持处理。
final passwordFreeInstallSupportedProvider = Provider<bool>((ref) {
  return ref.watch(linglongRuntimeFormProvider) ==
      LinglongRuntimeForm.hostInstalled;
});
