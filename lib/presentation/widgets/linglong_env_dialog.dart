/// 启动与功能入口共用的玲珑环境提示，保留浏览入口及原有安装修复能力。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/providers/linglong_env_provider.dart';
import '../../core/accessibility/accessibility.dart';
import '../../core/config/theme.dart';
import '../../core/i18n/install_messages.dart';
import '../../core/i18n/l10n/app_localizations.dart';
import '../../core/platform/local_path_opener.dart';
import '../../core/utils/app_notification_helpers.dart';
import '../../domain/models/linux_distribution.dart';
import '../../domain/models/linglong_env_check_result.dart';
import 'linglong_environment_management/environment_management_localizations.dart';

/// 玲珑环境检测对话框
///
/// 启动提醒和受限操作共用修复入口；关闭提醒只允许浏览，
/// 不会把缺失的环境标记为正常，也不会退出商店。
class LinglongEnvDialog extends ConsumerWidget {
  const LinglongEnvDialog({super.key, this.allowBrowse = true});

  /// 启动场景使用继续浏览，操作场景使用关闭，均不授权受限操作。
  final bool allowBrowse;

  /// 根导航器存活期内共享弹窗，避免启动提醒与连续点击叠加。
  static final Expando<Future<void>> _activeDialogs = Expando();

  /// 显示共享对话框，不执行额外检测；调用方可传入原页面的状态容器。
  ///
  /// 保留 forceShow 参数兼容既有入口，环境健康与否由调用方判断。
  static Future<void> show(
    BuildContext context, {
    bool forceShow = false,
    bool allowBrowse = true,
    ProviderContainer? container,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final active = _activeDialogs[navigator];
    if (active != null) {
      return active;
    }
    final dialogContainer =
        container ?? ProviderScope.containerOf(context, listen: false);
    late final Future<void> future;
    future =
        showDialog<void>(
          context: navigator.context,
          barrierDismissible: false,
          builder: (context) => UncontrolledProviderScope(
            container: dialogContainer,
            child: LinglongEnvDialog(allowBrowse: allowBrowse),
          ),
        ).whenComplete(() {
          if (identical(_activeDialogs[navigator], future)) {
            _activeDialogs[navigator] = null;
          }
        });
    _activeDialogs[navigator] = future;
    return future;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envState = ref.watch(linglongEnvProvider);

    // 特权安装没有真实取消能力；返回键也必须等待安装或服务修复完成。
    final isBusy =
        envState.isInstalling || envState.isRestartingPackageManagerService;
    return PopScope(
      canPop: !isBusy,
      child: A11yFocusScope(
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.smRadius,
            side: const BorderSide(color: AppColors.modalBorder),
          ),
          elevation: 0,
          backgroundColor: context.appColors.surface,
          title: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  envState.checkState == LinglongEnvCheckState.checking
                      ? Icons.info_outline
                      : (envState.result?.isOk ?? false
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_rounded),
                  color: envState.checkState == LinglongEnvCheckState.checking
                      ? AppColors.info
                      : (envState.result?.isOk ?? false
                            ? AppColors.success
                            : AppColors.warning),
                  size: 24,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.envCheckTitle,
                  style: context.appTextStyles.title3.copyWith(
                    color: context.appColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: _buildContent(context, ref, envState),
            ),
          ),
          actions: isBusy ? null : _buildActions(context, ref, envState),
        ),
      ),
    );
  }

  /// 构建内容区域
  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    LinglongEnvState envState,
  ) {
    if (envState.isInstalling) {
      return _buildInstallProgress(context, ref, envState);
    }

    if (envState.isChecking) {
      return _buildCheckingContent(context);
    }

    return _buildResultContent(context, ref, envState);
  }

  /// 构建检测中内容
  Widget _buildCheckingContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: AppSpacing.lg),
        const CircularProgressIndicator(),
        const SizedBox(height: AppSpacing.xl),
        Text(
          AppLocalizations.of(context)!.checkingLinglongEnv,
          style: context.appTextStyles.body.copyWith(
            color: context.appColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  /// 构建检测结果内容
  Widget _buildResultContent(
    BuildContext context,
    WidgetRef ref,
    LinglongEnvState envState,
  ) {
    final result = envState.result;

    if (result == null) {
      return Text(
        AppLocalizations.of(context)!.unknownStatus,
        style: context.appTextStyles.body.copyWith(
          color: context.appColors.textSecondary,
        ),
      );
    }

    final distributionGuidance = _resolveDistributionGuidance(context, result);
    final l10n = AppLocalizations.of(context)!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 状态摘要
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: result.isOk
                ? AppColors.success.withValues(alpha: 0.1)
                : AppColors.warning.withValues(alpha: 0.1),
            borderRadius: AppRadius.smRadius,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  result.isOk ? Icons.check_circle : Icons.error_outline,
                  color: result.isOk ? AppColors.success : AppColors.warning,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  localizeLinglongEnvironmentStatus(l10n, result),
                  style: context.appTextStyles.body.copyWith(
                    color: result.isOk ? AppColors.success : AppColors.warning,
                    fontWeight: context.appFontWeight(FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (!result.isOk) ...[
          const SizedBox(height: AppSpacing.md),
          // 先解释仍可体验的功能，再展示诊断，避免错误信息形成阻断感。
          Text(
            l10n.envBrowseNotice,
            style: context.appTextStyles.body.copyWith(
              color: context.appColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),

        if (distributionGuidance != null) ...[
          _buildDistributionGuidanceHint(context, distributionGuidance),
          const SizedBox(height: AppSpacing.lg),
        ],

        // 详细信息
        _buildDetailItem(
          context,
          AppLocalizations.of(context)!.llCliVersion,
          result.llCliVersion ?? AppLocalizations.of(context)!.notDetected,
          result.llCliVersion != null,
        ),

        // 错误信息
        if (!result.isOk) ...[
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.1),
              borderRadius: AppRadius.smRadius,
              border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const ExcludeSemantics(
                      child: Icon(
                        Icons.error_outline,
                        color: AppColors.error,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        result.shouldSuggestPackageManagerRestart
                            ? l10n.repoShowFailureTitle
                            : l10n.errorMessage,
                        style: context.appTextStyles.caption.copyWith(
                          color: AppColors.error,
                          fontWeight: context.appFontWeight(FontWeight.w500),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  localizeLinglongEnvironmentStatus(l10n, result),
                  style: context.appTextStyles.caption.copyWith(
                    color: context.appColors.textSecondary,
                  ),
                ),
                if (result.errorDetail != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Tooltip(
                    message: result.errorDetail!,
                    child: SelectableText(
                      result.errorDetail ?? '',
                      style: context.appTextStyles.tiny.copyWith(
                        color: context.appColors.textTertiary,
                      ),
                    ),
                  ),
                ],
                // 诊断允许键盘操作与复制，便于用户查文档或反馈问题。
                _accessibleAction(
                  label: l10n.a11yCopyLinglongEnvironmentDiagnostic,
                  onPressed: () => _copyDiagnostic(l10n, result),
                  child: TextButton(
                    onPressed: () => _copyDiagnostic(l10n, result),
                    child: Text(l10n.copyErrorMessage),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (result.shouldSuggestPackageManagerRestart) ...[
          const SizedBox(height: AppSpacing.md),
          _buildPackageManagerRestartHint(context, ref, envState, result),
        ],
      ],
    );
  }

  /// 将当前语言的状态摘要和原始诊断一起复制，便于准确反馈问题。
  void _copyDiagnostic(AppLocalizations l10n, LinglongEnvCheckResult result) {
    Clipboard.setData(
      ClipboardData(
        text: [
          localizeLinglongEnvironmentStatus(l10n, result),
          if (result.errorDetail != null) result.errorDetail!,
        ].join('\n'),
      ),
    );
  }

  /// 构建包管理器服务重启提示。
  ///
  /// 该提示只在 `ll-cli --json repo show` 仓库读取命令失败时展示，
  /// 展示层不直接执行 `systemctl`，只把用户点击交给 Provider 的受控动作。
  Widget _buildPackageManagerRestartHint(
    BuildContext context,
    WidgetRef ref,
    LinglongEnvState envState,
    LinglongEnvCheckResult result,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final command = result.failedCommand ?? 'll-cli --json repo show';
    final isRestarting = envState.isRestartingPackageManagerService;
    final restartDiagnostic = envState.serviceRestartMessage;
    final restartMessage = restartDiagnostic == null
        ? null
        : isRestarting
        ? l10n.restartingPackageManagerService
        : l10n.packageManagerServiceRestartFailed(restartDiagnostic);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: AppRadius.smRadius,
        border: Border.all(color: AppColors.info.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: Icon(Icons.info_outline, color: AppColors.info, size: 18),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.repoShowFailureInstalledQuestion,
                  style: context.appTextStyles.caption.copyWith(
                    color: context.appColors.textPrimary,
                    fontWeight: context.appFontWeight(FontWeight.w600),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.repoShowFailureCommand(command),
                  style: context.appTextStyles.caption.copyWith(
                    color: context.appColors.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.repoShowFailureReason,
                  style: context.appTextStyles.caption.copyWith(
                    color: context.appColors.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.repoShowFailureRestartHint,
                  style: context.appTextStyles.caption.copyWith(
                    color: context.appColors.textSecondary,
                    height: 1.35,
                  ),
                ),
                if (restartMessage != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    restartMessage,
                    style: context.appTextStyles.tiny.copyWith(
                      color: context.appColors.textTertiary,
                      height: 1.3,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: _accessibleAction(
                    label: l10n.a11yRestartLinglongPackageManagerService,
                    enabled: !isRestarting,
                    onPressed: () =>
                        _handleRestartPackageManagerService(context, ref),
                    child: TextButton(
                      onPressed: isRestarting
                          ? null
                          : () => _handleRestartPackageManagerService(
                              context,
                              ref,
                            ),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.info,
                        // 按钮内容随文本方向镜像
                        alignment: AlignmentDirectional.centerStart,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Row(
                        children: [
                          if (isRestarting)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const ExcludeSemantics(
                              child: Icon(Icons.restart_alt, size: 16),
                            ),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(
                              isRestarting
                                  ? l10n.restartingPackageManagerService
                                  : l10n.restartPackageManagerService,
                              softWrap: true,
                              style: context.appTextStyles.caption.copyWith(
                                color: isRestarting
                                    ? context.appColors.textTertiary
                                    : AppColors.info,
                                fontWeight: context.appFontWeight(
                                  FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _resolveDistributionGuidance(
    BuildContext context,
    LinglongEnvCheckResult result,
  ) {
    final l10n = AppLocalizations.of(context)!;

    // 对话框只负责“按当前场景请求 guidance”，
    // 不直接知道 UOS/Deepin 等发行版细节，避免弹窗逻辑再次退化成 `if (isXxx)`。
    return InstallMessages.fromL10n(l10n).guidanceForDistribution(
      distribution: result.distribution,
      scenario: LinuxDistributionGuidanceScenario.envInstallDialog,
    );
  }

  Widget _buildDistributionGuidanceHint(BuildContext context, String guidance) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: AppRadius.smRadius,
        border: Border.all(color: AppColors.info.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: Icon(Icons.info_outline, color: AppColors.info, size: 18),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              guidance,
              style: AppTextStyles.caption.copyWith(
                color: context.appColors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建详情项
  Widget _buildDetailItem(
    BuildContext context,
    String label,
    String value,
    bool isOk,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: context.appTextStyles.caption.copyWith(
              color: context.appColors.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  isOk ? Icons.check : Icons.close,
                  color: isOk ? AppColors.success : AppColors.error,
                  size: 14,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                value,
                style: context.appTextStyles.body.copyWith(
                  color: context.appColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建安装进度
  Widget _buildInstallProgress(
    BuildContext context,
    WidgetRef ref,
    LinglongEnvState envState,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          width: 280,
          child: LinearProgressIndicator(
            value: envState.installProgress,
            backgroundColor: context.appColors.cardBackground,
            // 安装进度强调色改为 build 时读当前主题（docs/48 §7.5），
            // 去掉 const 后行为一致，系统强调色变化时能跟随更新。
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).colorScheme.primary,
            ),
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppLocalizations.of(context)!.installingLinglong,
          style: context.appTextStyles.body.copyWith(
            color: context.appColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppLocalizations.of(context)!.envInstallationInProgressNotice,
          style: context.appTextStyles.caption.copyWith(
            color: context.appColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        if (envState.installLogFilePath != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            envState.installLogFilePath!,
            style: context.appTextStyles.tiny.copyWith(
              color: context.appColors.textTertiary,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildOpenInstallLogButton(
            context,
            ref,
            envState.installLogFilePath!,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  /// 统一动作语义，沿用原有安装与重检流程。
  List<Widget> _buildActions(
    BuildContext context,
    WidgetRef ref,
    LinglongEnvState envState,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final canRepair = !envState.isChecking;
    final closeLabel = allowBrowse ? l10n.continueBrowsing : l10n.close;
    return [
      // 浏览始终允许，关闭提醒不会启动任何需要玲珑环境的操作。
      _accessibleAction(
        label: allowBrowse ? l10n.a11yContinueBrowsing : l10n.a11yClose,
        onPressed: () => _handleContinueBrowsing(context, ref),
        child: TextButton(
          onPressed: () => _handleContinueBrowsing(context, ref),
          child: Text(closeLabel),
        ),
      ),
      _accessibleAction(
        label: l10n.a11yManualLinglongEnvironmentInstallation,
        onPressed: () => _handleManualInstall(context, ref),
        child: TextButton.icon(
          onPressed: () => _handleManualInstall(context, ref),
          icon: const ExcludeSemantics(
            child: Icon(Icons.open_in_new, size: 16),
          ),
          label: Text(l10n.manualInstall),
          style: TextButton.styleFrom(foregroundColor: AppColors.info),
        ),
      ),
      if (envState.installLogFilePath != null)
        _buildOpenInstallLogButton(context, ref, envState.installLogFilePath!),
      _accessibleAction(
        label: l10n.a11yConfigureLinglongEnvironment,
        enabled: canRepair && envState.result?.isOk != true,
        onPressed: () => _handleAutoInstall(context, ref),
        child: FilledButton.icon(
          onPressed: canRepair && envState.result?.isOk != true
              ? () => _handleAutoInstall(context, ref)
              : null,
          icon: const ExcludeSemantics(child: Icon(Icons.download, size: 16)),
          label: Text(l10n.autoInstall),
        ),
      ),
      _accessibleAction(
        label: l10n.a11yRecheckLinglongEnvironment,
        enabled: canRepair,
        onPressed: () => _handleRecheck(context, ref),
        child: OutlinedButton.icon(
          onPressed: canRepair ? () => _handleRecheck(context, ref) : null,
          icon: const ExcludeSemantics(child: Icon(Icons.refresh, size: 16)),
          label: Text(l10n.recheck),
          style: OutlinedButton.styleFrom(
            foregroundColor: context.appColors.textPrimary,
            side: BorderSide(color: context.appColors.border),
          ),
        ),
      ),
    ];
  }

  /// 按钮语义统一使用项目封装，避免各场景遗漏禁用状态。
  Widget _accessibleAction({
    required String label,
    required VoidCallback onPressed,
    required Widget child,
    bool enabled = true,
  }) => A11yButton(
    semanticsLabel: label,
    onTap: onPressed,
    enabled: enabled,
    child: child,
  );

  /// 安装期间保留日志入口，便于查看进度和诊断，但不提供虚假的取消。
  Widget _buildOpenInstallLogButton(
    BuildContext context,
    WidgetRef ref,
    String logFilePath,
  ) {
    final l10n = AppLocalizations.of(context)!;
    void openLog() => _handleOpenInstallLogDirectory(context, ref, logFilePath);
    return _accessibleAction(
      label: l10n.a11yOpenLinglongInstallLogDirectory,
      onPressed: openLog,
      child: OutlinedButton.icon(
        onPressed: openLog,
        icon: const ExcludeSemantics(child: Icon(Icons.folder_open, size: 16)),
        label: Text(l10n.openInstallLogDirectory),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.info,
          side: const BorderSide(color: AppColors.info),
        ),
      ),
    );
  }

  /// 处理手动安装
  Future<void> _handleManualInstall(BuildContext context, WidgetRef ref) async {
    final envNotifier = ref.read(linglongEnvProvider.notifier);
    final url = envNotifier.getInstallDocUrl();

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (context.mounted) {
        showAppError(
          context,
          AppLocalizations.of(context)!.cannotOpenLink(url),
        );
      }
    }
  }

  /// 处理自动安装
  Future<void> _handleAutoInstall(BuildContext context, WidgetRef ref) async {
    final success = await ref
        .read(linglongEnvProvider.notifier)
        .performAutoInstall();

    if (success && context.mounted) {
      // 自动安装成功后检查环境是否正常
      final envState = ref.read(linglongEnvProvider);
      if (envState.result?.isOk ?? false) {
        // 环境正常，关闭对话框，由 launch_page 继续启动流程
        Navigator.of(context).pop();
        showAppSuccess(context, AppLocalizations.of(context)!.envCheckPassed);
      } else {
        // 环境仍异常，提示用户
        showAppWarning(context, AppLocalizations.of(context)!.envCheckFailed);
      }
    }
  }

  Future<void> _handleOpenInstallLogDirectory(
    BuildContext context,
    WidgetRef ref,
    String logFilePath,
  ) async {
    final directoryPath = File(logFilePath).parent.path;
    final opened = await ref
        .read(localPathOpenerProvider)
        .openDirectory(directoryPath);
    if (!opened && context.mounted) {
      showAppError(
        context,
        AppLocalizations.of(context)!.cannotOpenDirectory(directoryPath),
      );
    }
  }

  /// 处理重新检测
  Future<void> _handleRecheck(BuildContext context, WidgetRef ref) async {
    await ref.read(linglongEnvProvider.notifier).recheck();
    if (!context.mounted) return;
    // 重新检测后如果环境正常，关闭对话框
    final envState = ref.read(linglongEnvProvider);
    if (envState.result?.isOk ?? false) {
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  /// 处理包管理器服务重启。
  ///
  /// 用户点击该入口表示已经确认本机安装了玲珑应用环境；
  /// 具体特权命令由 Provider/Service 受控执行，UI 只负责反馈结果。
  Future<void> _handleRestartPackageManagerService(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final success = await ref
        .read(linglongEnvProvider.notifier)
        .restartPackageManagerServiceAndRecheck();

    if (!context.mounted) {
      return;
    }

    final envState = ref.read(linglongEnvProvider);
    if (success && (envState.result?.isOk ?? false)) {
      Navigator.of(context).pop();
      showAppSuccess(context, l10n.packageManagerServiceRestartPassed);
      return;
    }

    final restartMessage = envState.serviceRestartMessage;
    if (restartMessage != null && restartMessage.trim().isNotEmpty) {
      showAppError(
        context,
        l10n.packageManagerServiceRestartFailed(restartMessage),
      );
      return;
    }

    showAppWarning(context, l10n.packageManagerServiceRestartStillFailed);
  }

  /// 关闭环境提醒并继续浏览；真实检测结果保持不变。
  ///
  /// 仅启动提醒记住本次已浏览，操作提示关闭也不能授权安装或更新。
  void _handleContinueBrowsing(BuildContext context, WidgetRef ref) {
    if (allowBrowse) {
      ref.read(linglongEnvProvider.notifier).skipCheck();
    }
    Navigator.of(context).pop();
  }
}

/// 玲珑环境对话框包装器
///
/// 用于在启动时自动检测并显示对话框
class LinglongEnvDialogWrapper extends ConsumerStatefulWidget {
  const LinglongEnvDialogWrapper({
    super.key,
    required this.child,
    this.onEnvOk,
    this.onEnvFailed,
  });

  /// 子组件
  final Widget child;

  /// 环境正常回调
  final VoidCallback? onEnvOk;

  /// 环境异常回调
  final VoidCallback? onEnvFailed;

  @override
  ConsumerState<LinglongEnvDialogWrapper> createState() =>
      _LinglongEnvDialogWrapperState();
}

class _LinglongEnvDialogWrapperState
    extends ConsumerState<LinglongEnvDialogWrapper> {
  bool _hasChecked = false;
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkEnvironment();
    });
  }

  Future<void> _checkEnvironment() async {
    if (_hasChecked) return;
    _hasChecked = true;

    final result = await ref
        .read(linglongEnvProvider.notifier)
        .checkEnvironment();

    if (result.isOk) {
      widget.onEnvOk?.call();
    } else {
      widget.onEnvFailed?.call();
      if (mounted && !_dialogShown) {
        _dialogShown = true;
        await LinglongEnvDialog.show(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
