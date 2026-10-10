/// 容器 → 宿主的命令透传通道（玲珑容器形态专用）。
///
/// 业务定位：
///   玲珑（UAB）形态下容器里没有 ll-cli，也没有宿主的玲珑守护进程、层仓库
///   （宿主 `/var/lib/linglong`）与可写状态；这些命令只能在宿主机上执行。本文件
///   提供唯一一条"容器内发起、宿主上执行"的命令包装通道，供 ll-cli 等宿主工具复用。
///
/// 为什么能跨出去：
///   容器与宿主共享用户会话总线（`/run/user/1000/bus`）。`systemd-run --user` 经该
///   总线请求宿主上的用户 systemd 管理器创建瞬态 unit，进程因此落在容器之外；
///   `--wait --pipe` 把退出码与 stdout/stderr 原样带回。
///
/// 为什么不直接执行宿主根挂载点下的二进制：
///   实测容器内直调 `/run/host/rootfs/usr/bin/ll-cli` 只能打印 `--version`，
///   `ll-cli list` 会静默失败——它依赖宿主命名空间内的守护进程与状态目录。
///
/// 安全边界（必须评审）：
///   这是一条**沙箱逃逸**通道：能到达宿主的命令完全由调用方给出的 argv 决定，
///   通道本身不限制子命令。能力面的收敛责任在调用方（例如 ll-cli 只允许商店真正
///   需要的子命令），并且必须在设计文档中写明。
///
/// 实测约束（实现里逐条对应，改动前请先复验）：
///   1. `systemd-run` **不转发调用者环境变量**——必须用 `--setenv` 显式声明，
///      否则 ll-cli 输出会随宿主语言变化，破坏 JSON/文本解析；
///   2. `systemd-run` 默认会展开命令串里的 `$` 形式（`$$` 会被改写），必须传
///      `--expand-environment=no`；
///   3. `--working-directory` 指向宿主上不存在的路径时**静默失败**（退出码 200、
///      无任何输出），因此只能用容器与宿主同路径的目录（家目录）；
///   4. 宿主视角的可执行文件路径不能带宿主根挂载点前缀——脚本在宿主上执行，
///      宿主没有 `/run/host/rootfs`。
library;

import 'dart:io';

/// 宿主透传通道的探测结果与命令包装。
class HostEscapeChannel {
  /// 创建通道事实。
  ///
  /// 只应由 [detect] 构造；构造器保持公开是为了测试注入。
  const HostEscapeChannel({
    required this.hostRootfs,
    required this.launcherPath,
    this.workingDirectory,
  });

  /// 容器内宿主根文件系统的只读挂载点。
  static const String defaultHostRootfsPath = '/run/host/rootfs';

  /// 宿主上用于启动程序的启动器（容器内可执行的绝对路径）。
  static const String launcherName = 'systemd-run';

  /// 宿主上可能安放工具链的目录（相对宿主根），按优先级排列。
  static const List<String> hostSearchDirs = <String>[
    'usr/bin',
    'usr/local/bin',
    'bin',
  ];

  /// 宿主根文件系统的只读挂载点（容器内路径）。
  final String hostRootfs;

  /// 启动器在容器内的绝对路径。
  final String launcherPath;

  /// 透传时使用的工作目录。
  ///
  /// 必须是容器与宿主**同路径**的目录：玲珑把家目录两侧同路径挂载，而容器内的
  /// 应用目录（`/opt/apps/<appid>/...`）在宿主上并不存在，用它会让宿主进程
  /// chdir 失败并静默返回 200。为 null 时不传 `--working-directory`。
  final String? workingDirectory;

  /// 探测当前进程是否具备宿主透传通道。
  ///
  /// 判据缺一不可，任一不满足即返回 null，调用方必须保持容器内的既有行为：
  ///   1. 宿主根只读挂载点存在——只有玲珑容器会挂载它；
  ///   2. 启动器在 PATH 上可解析；
  ///   3. 用户会话总线可用——`systemd-run --user` 必须经它请求宿主管理器。
  ///
  /// [isDirectory]、[lookPath]、[environment] 均为测试注入点；生产代码不传参。
  static HostEscapeChannel? detect({
    Map<String, String>? environment,
    String hostRootfsPath = defaultHostRootfsPath,
    bool Function(String path)? isDirectory,
    String? Function(String name)? lookPath,
  }) {
    final env = environment ?? const <String, String>{};
    final directoryExists = isDirectory ?? _defaultIsDirectory;
    final resolve = lookPath ?? _defaultLookPath;

    if (!directoryExists(hostRootfsPath)) {
      return null;
    }

    final launcher = resolve(launcherName);
    if (launcher == null || launcher.isEmpty) {
      return null;
    }

    if (!_sessionBusAvailable(env)) {
      return null;
    }

    return HostEscapeChannel(
      hostRootfs: hostRootfsPath,
      launcherPath: launcher,
      workingDirectory: _sharedWorkingDirectory(env, directoryExists),
    );
  }

  /// 在宿主根挂载点下探测 [name]，返回**宿主视角**的绝对路径。
  ///
  /// 探测发生在容器内（宿主根挂载点下），返回值不带挂载点前缀——包装脚本在宿主上
  /// 执行，宿主没有挂载点这个路径。只接受普通文件且带执行位：能力"不存在"好过
  /// "看得见但一用就报错"。
  ///
  /// [isExecutableFile] 是测试注入点。
  String? hostExecutable(
    String name, {
    List<String> searchDirs = hostSearchDirs,
    bool Function(String path)? isExecutableFile,
  }) {
    final executable = isExecutableFile ?? _defaultIsExecutableFile;
    for (final dir in searchDirs) {
      final containerPath = '$hostRootfs/$dir/$name';
      if (!executable(containerPath)) {
        continue;
      }
      return '/$dir/$name';
    }
    return null;
  }

  /// 把宿主命令包装为容器内可直接启动的命令。
  ///
  /// [hostCommand] 首元素是**宿主视角**的可执行文件绝对路径，其余为参数。
  /// [environment] 需要显式声明给宿主 unit 的环境变量（见文件头实测约束 1）。
  ///
  /// 形态固定为 `systemd-run … /bin/sh -c 'exec "$0" "$@"' <宿主命令> <参数>`：
  /// 用 `$0` 承载宿主命令路径、`$@` 承载参数，避免在 shell 里拼引号，带空格或
  /// 非 ASCII 的参数也原样透传。
  List<String> wrap(
    List<String> hostCommand, {
    Map<String, String> environment = const <String, String>{},
  }) {
    if (hostCommand.isEmpty) {
      throw ArgumentError.value(hostCommand, 'hostCommand', '宿主命令不能为空');
    }

    return <String>[
      launcherPath,
      '--user',
      '--quiet',
      '--collect',
      '--wait',
      '--pipe',
      // 约束 2：禁止 systemd 展开命令串里的 $ 形式，否则参数会被静默改坏。
      '--expand-environment=no',
      // 约束 1：调用者环境不会自动进入宿主 unit，必须显式声明。
      for (final entry in environment.entries)
        '--setenv=${entry.key}=${entry.value}',
      // 约束 3：只传两侧同路径的目录。
      if (workingDirectory != null) '--working-directory=$workingDirectory',
      '/bin/sh',
      '-c',
      'exec "\$0" "\$@"',
      ...hostCommand,
    ];
  }

  /// 判断用户会话总线是否可用。
  ///
  /// 优先看显式地址；缺失时退回 XDG 运行时目录（`systemd-run --user` 会自己找
  /// `$XDG_RUNTIME_DIR/bus`）。两者都没有时通道不可用——没有总线就没有宿主管理器。
  static bool _sessionBusAvailable(Map<String, String> environment) {
    final address = environment['DBUS_SESSION_BUS_ADDRESS'];
    if (address != null && address.trim().isNotEmpty) {
      return true;
    }
    final runtimeDir = environment['XDG_RUNTIME_DIR'];
    return runtimeDir != null && runtimeDir.trim().isNotEmpty;
  }

  /// 取两侧同路径的工作目录；家目录不可用时返回 null（宁可不传，也不传错）。
  static String? _sharedWorkingDirectory(
    Map<String, String> environment,
    bool Function(String path) directoryExists,
  ) {
    final home = environment['HOME'];
    if (home == null || !home.startsWith('/') || !directoryExists(home)) {
      return null;
    }
    return home;
  }

  static bool _defaultIsDirectory(String path) =>
      Directory(path).existsSync();

  static bool _defaultIsExecutableFile(String path) {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return false;
    }
    // 0o111：属主/属组/其他任一执行位。
    final mode = File(path).statSync().mode;
    return (mode & 0x49) != 0;
  }

  static String? _defaultLookPath(String name) {
    for (final dir in _defaultPathEntries()) {
      final candidate = '$dir/$name';
      if (_defaultIsExecutableFile(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  static List<String> _defaultPathEntries() {
    final path = Platform.environment['PATH'] ?? '';
    return path
        .split(':')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  }
}
