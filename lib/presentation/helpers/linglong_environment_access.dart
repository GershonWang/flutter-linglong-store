/// 玲珑能力的统一交互入口。
///
/// 浏览不依赖玲珑；安装、更新等操作必须读取真实环境结果，
/// 复用启动检测缓存并合并并发请求，避免每次点击执行 CLI 或叠加弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/linglong_env_provider.dart';
import '../../application/providers/launch_provider.dart';
import '../widgets/linglong_env_dialog.dart';

export '../widgets/linglong_environment_required_view.dart';

/// 以根导航器作为生命周期边界，不持有可能被页面切换销毁的 Context。
final Expando<Future<bool>> _pendingEnvironmentAccess = Expando();

/// 启动提醒与操作提示共用一个弹窗；展示已有检测结果，不额外探测。
Future<void> showLinglongEnvironmentDialog(
  BuildContext context, {
  bool allowBrowse = false,
}) {
  if (!context.mounted) return Future.value();
  return LinglongEnvDialog.show(context, allowBrowse: allowBrowse);
}

/// 检查需要玲珑的操作是否可以继续。
///
/// 跳过提示只允许浏览，不能作为权限依据。尚未检测时复用 Provider
/// 检测，已知不可用时直接提示；安装或重检成功后才返回 true。
Future<bool> ensureLinglongEnvironment(BuildContext context, WidgetRef ref) {
  if (!context.mounted) return Future.value(false);
  final cached = ref.read(linglongEnvProvider).result;
  if (cached?.isOk == true) {
    final launch = ref.read(launchSequenceProvider);
    if (!launch.isCompleted || !launch.isBrowseOnly) return Future.value(true);
  }

  final navigator = Navigator.of(context, rootNavigator: true);
  final pending = _pendingEnvironmentAccess[navigator];
  if (pending != null) return pending;
  final container = ProviderScope.containerOf(context, listen: false);

  late final Future<bool> future;
  future = _checkAndPrompt(navigator, container).whenComplete(() {
    if (identical(_pendingEnvironmentAccess[navigator], future)) {
      _pendingEnvironmentAccess[navigator] = null;
    }
  });
  _pendingEnvironmentAccess[navigator] = future;
  return future;
}

/// 异步阶段只使用稳定根导航器，页面 Context 和 WidgetRef 不跨 await。
Future<bool> _checkAndPrompt(
  NavigatorState navigator,
  ProviderContainer container,
) async {
  var result = container.read(linglongEnvProvider).result;
  result ??= await container
      .read(linglongEnvProvider.notifier)
      .checkEnvironment();
  if (!navigator.mounted) return false;
  if (result.isOk) return _authorizeAfterRuntimeRecovery(navigator, container);

  await LinglongEnvDialog.show(
    navigator.context,
    allowBrowse: false,
    container: container,
  );
  if (!navigator.mounted) return false;
  if (container.read(linglongEnvProvider).result?.isOk != true) return false;
  return _authorizeAfterRuntimeRecovery(navigator, container);
}

/// 环境修复成功后先等本机初始化，防止新任务与崩溃队列恢复互相覆盖。
///
/// 初始启动编排未完成时由启动页面负责等待；已进入浏览模式时才需要
/// 合并并等待后台恢复。恢复失败保留浏览权限，但不能继续受限操作。
Future<bool> _authorizeAfterRuntimeRecovery(
  NavigatorState navigator,
  ProviderContainer container,
) async {
  final launch = container.read(launchSequenceProvider);
  if (launch.isCompleted && launch.isBrowseOnly) {
    await container
        .read(launchSequenceProvider.notifier)
        .continueAfterEnvCheck();
    if (!navigator.mounted) return false;
    if (container.read(launchSequenceProvider).isBrowseOnly) return false;
  }
  return container.read(linglongEnvProvider).result?.isOk == true;
}
