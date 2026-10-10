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

/// ll-cli 在 PATH 上的命令名。
///
/// 仅默认实现使用；透传实现不使用它（宿主侧的可执行文件路径由透传实现自己决定，
/// 因为容器内路径在宿主上并不存在）。
const String kLlCliPath = 'll-cli';

/// 把 ll-cli 参数解析为可直接执行的外部命令。
abstract interface class LinglongCliCommandBuilder {
  /// 构造命令。
  ///
  /// [args] 是 ll-cli 的子命令与参数（不含命令名本身，例如 `['list', '--json']`）。
  /// 返回值首元素为可执行文件，其余为参数；实现必须保证返回值非空。
  List<String> build(List<String> args);
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
