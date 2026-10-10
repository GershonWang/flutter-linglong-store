/// ll-cli 命令的统一构造入口。
///
/// 业务定位：
///   商店对 ll-cli 的所有调用都必须经过本入口构造"真正要执行的外部命令"，禁止各
///   服务自行拼 `'ll-cli'` 字面量。命令形态一旦在多处各自拼接，任何执行方式变更
///   都会漏掉调用点——环境检测与安装编排就曾各写一份。
///
/// 为什么需要这一层：
///   玲珑（UAB）形态下容器内没有 ll-cli，需要把命令透传到宿主执行；透传会改变
///   可执行文件与参数前缀（不再是 `ll-cli <args>`）。把命令构造收敛到一处之后，
///   接入透传只需替换实现，所有调用点无需感知。
///
/// 调用约束：
///   返回值的首元素是**可执行文件**，其余为参数，可直接交给 `Process.start`；
///   构造器只负责命令形态，不负责环境变量、超时与取消语义。
library;

import 'host_escape_channel.dart';

/// ll-cli 在 PATH 上的命令名。
///
/// 仅默认实现使用；透传实现不使用它（宿主侧的可执行文件路径由透传实现自己决定，
/// 因为容器内路径在宿主上并不存在）。
const String kLlCliPath = 'll-cli';

/// 强制英文 locale 的环境变量。
///
/// ll-cli 的输出要被 JSON 与文本表格解析，不能随宿主语言变化；本地执行与宿主透传
/// 都必须带上同一份。收敛前 CliExecutor 与环境检测各写了一份，容易漂移。
const Map<String, String> kEnglishLocaleEnvironment = <String, String>{
  'LC_ALL': 'C.UTF-8',
  'LANG': 'C.UTF-8',
  'LANGUAGE': 'C.UTF-8',
  'LC_MESSAGES': 'C.UTF-8',
};

/// 把 ll-cli 参数解析为可直接执行的外部命令。
abstract interface class LinglongCliCommandBuilder {
  /// 构造命令。
  ///
  /// [args] 是 ll-cli 的子命令与参数（不含命令名本身，例如 `['list', '--json']`）。
  /// 返回值首元素为可执行文件，其余为参数；实现必须保证返回值非空。
  List<String> build(List<String> args);
}

/// 当前生效的 ll-cli 命令构造器。
///
/// 由组合根在启动期用 [configureLinglongCliCommandBuilder] 设置一次。
///
/// 为什么用进程级持有者而不是逐层注入：命令形态（本地直调 / 宿主透传）是**进程级
/// 事实**——商店是单进程桌面应用，运行形态在进程生命周期内不会变化；而 ll-cli 的
/// 调用点跨 Repository、Service、Provider 三层，逐层注入会把同一个构造器穿过十余个
/// 构造器。收敛前正是因为命令形态散落各处才漏掉了 `runApp`，这里刻意让"读哪里"
/// 只有一个答案。
LinglongCliCommandBuilder _activeBuilder =
    const LocalLinglongCliCommandBuilder();

/// 读取当前生效的命令构造器。
LinglongCliCommandBuilder get linglongCliCommandBuilder => _activeBuilder;

/// 安装命令构造器（组合根在启动期调用一次）。
///
/// 重复调用会覆盖上一次结果，便于测试与形态切换。
void configureLinglongCliCommandBuilder(LinglongCliCommandBuilder builder) {
  _activeBuilder = builder;
}

/// 默认实现：直接调用 PATH 上的 ll-cli。
///
/// DEB / RPM / AppImage 形态与开发态都走这一条，行为与收敛前完全一致。
class LocalLinglongCliCommandBuilder implements LinglongCliCommandBuilder {
  /// 创建默认实现。
  const LocalLinglongCliCommandBuilder();

  @override
  List<String> build(List<String> args) => <String>[kLlCliPath, ...args];
}

/// 玲珑容器形态：把 ll-cli 命令透传到宿主机执行。
///
/// 容器内没有 ll-cli——玲珑 base 镜像不含玲珑工具链，且 ll-cli 依赖 Qt6 等宿主库，
/// 打进包要连带一堆依赖。因此这里把命令送回宿主执行：宿主本来就有完整的 ll-cli
/// 与玲珑环境。命令形态与本地实现完全不同，但对调用方透明。
class BridgedLinglongCliCommandBuilder implements LinglongCliCommandBuilder {
  /// 创建透传实现。
  BridgedLinglongCliCommandBuilder({
    required this.channel,
    required this.hostLlCliPath,
    this.environment = kEnglishLocaleEnvironment,
  });

  /// 宿主透传通道（探测结果）。
  final HostEscapeChannel channel;

  /// 宿主视角的 ll-cli 绝对路径，不带宿主根挂载点前缀。
  final String hostLlCliPath;

  /// 显式声明给宿主 unit 的环境变量。
  ///
  /// 必须显式传：`systemd-run` 不转发调用者环境变量，缺失会让 ll-cli 按宿主语言
  /// 输出，直接破坏 JSON 解析。
  final Map<String, String> environment;

  @override
  List<String> build(List<String> args) => channel.wrap(
    <String>[hostLlCliPath, ...args],
    environment: environment,
  );
}
