import 'package:flutter_test/flutter_test.dart';

import 'package:linglong_store/core/platform/host_escape_channel.dart';
import 'package:linglong_store/core/platform/linglong_cli_command.dart';

/// 探测用的假文件系统：只认识列出的目录与可执行文件。
class _FakeFs {
  _FakeFs({required this.directories, required this.executables});

  final Set<String> directories;
  final Set<String> executables;

  bool isDirectory(String path) => directories.contains(path);

  bool isExecutableFile(String path) => executables.contains(path);
}

void main() {
  group('HostEscapeChannel.detect', () {
    test('挂载点、启动器、会话总线齐备时返回通道', () {
      final fs = _FakeFs(
        directories: <String>{'/run/host/rootfs', '/home/tester'},
        executables: <String>{'/bin/systemd-run'},
      );

      final channel = HostEscapeChannel.detect(
        environment: const <String, String>{
          'HOME': '/home/tester',
          'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
        },
        isDirectory: fs.isDirectory,
        lookPath: (name) => name == 'systemd-run' ? '/bin/systemd-run' : null,
      );

      expect(channel, isNotNull);
      expect(channel!.hostRootfs, equals('/run/host/rootfs'));
      expect(channel.launcherPath, equals('/bin/systemd-run'));
      expect(channel.workingDirectory, equals('/home/tester'));
    });

    test('缺少宿主根挂载点时没有通道', () {
      final fs = _FakeFs(
        directories: <String>{'/home/tester'},
        executables: <String>{'/bin/systemd-run'},
      );

      final channel = HostEscapeChannel.detect(
        environment: const <String, String>{
          'HOME': '/home/tester',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
        isDirectory: fs.isDirectory,
        lookPath: (name) => '/bin/$name',
      );

      expect(channel, isNull);
    });

    test('缺少启动器时没有通道', () {
      final fs = _FakeFs(
        directories: <String>{'/run/host/rootfs', '/home/tester'},
        executables: const <String>{},
      );

      final channel = HostEscapeChannel.detect(
        environment: const <String, String>{
          'HOME': '/home/tester',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
        isDirectory: fs.isDirectory,
        lookPath: (name) => null,
      );

      expect(channel, isNull);
    });

    test('没有会话总线时没有通道', () {
      final fs = _FakeFs(
        directories: <String>{'/run/host/rootfs', '/home/tester'},
        executables: <String>{'/bin/systemd-run'},
      );

      final channel = HostEscapeChannel.detect(
        environment: const <String, String>{'HOME': '/home/tester'},
        isDirectory: fs.isDirectory,
        lookPath: (name) => '/bin/$name',
      );

      expect(channel, isNull);
    });

    test('家目录不存在时不传工作目录', () {
      final fs = _FakeFs(
        directories: <String>{'/run/host/rootfs'},
        executables: <String>{'/bin/systemd-run'},
      );

      final channel = HostEscapeChannel.detect(
        environment: const <String, String>{
          'HOME': '/home/missing',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
        isDirectory: fs.isDirectory,
        lookPath: (name) => '/bin/$name',
      );

      expect(channel, isNotNull);
      expect(channel!.workingDirectory, isNull);
    });
  });

  group('HostEscapeChannel.hostExecutable', () {
    test('返回宿主视角路径且不带挂载点前缀', () {
      final fs = _FakeFs(
        directories: const <String>{},
        executables: <String>{'/run/host/rootfs/usr/bin/ll-cli'},
      );
      const channel = HostEscapeChannel(
        hostRootfs: '/run/host/rootfs',
        launcherPath: '/bin/systemd-run',
      );

      expect(
        channel.hostExecutable('ll-cli', isExecutableFile: fs.isExecutableFile),
        equals('/usr/bin/ll-cli'),
      );
    });

    test('宿主上没有该命令时返回 null', () {
      final fs = _FakeFs(
        directories: const <String>{},
        executables: const <String>{},
      );
      const channel = HostEscapeChannel(
        hostRootfs: '/run/host/rootfs',
        launcherPath: '/bin/systemd-run',
      );

      expect(
        channel.hostExecutable('ll-cli', isExecutableFile: fs.isExecutableFile),
        isNull,
      );
    });
  });

  group('HostEscapeChannel.wrap', () {
    const channel = HostEscapeChannel(
      hostRootfs: '/run/host/rootfs',
      launcherPath: '/bin/systemd-run',
      workingDirectory: '/home/tester',
    );

    test('命令形态固定且参数原样透传', () {
      final command = channel.wrap(
        const <String>['/usr/bin/ll-cli', 'install', '--json', 'app id'],
        environment: const <String, String>{'LC_ALL': 'C.UTF-8'},
      );

      expect(command.first, equals('/bin/systemd-run'));
      // 从 /bin/sh 起是桥的固定尾部：桥接器 + 宿主命令 + 原样透传的参数。
      expect(
        command.sublist(command.indexOf('/bin/sh')),
        equals(const <String>[
          '/bin/sh',
          '-c',
          'exec "\$0" "\$@"',
          '/usr/bin/ll-cli',
          'install',
          '--json',
          'app id',
        ]),
      );
      // 参数必须逐个透传，不能在 shell 里拼串。
      expect(command, contains('app id'));
    });

    test('必须禁止 systemd 展开美元符号形式并显式声明环境变量', () {
      final command = channel.wrap(
        const <String>['/usr/bin/ll-cli', 'list'],
        environment: const <String, String>{
          'LC_ALL': 'C.UTF-8',
          'LANG': 'C.UTF-8',
        },
      );

      expect(command, contains('--expand-environment=no'));
      expect(command, contains('--setenv=LC_ALL=C.UTF-8'));
      expect(command, contains('--setenv=LANG=C.UTF-8'));
      expect(command, contains('--wait'));
      expect(command, contains('--pipe'));
      expect(command, contains('--working-directory=/home/tester'));
    });

    test('没有工作目录时不传 --working-directory', () {
      const withoutCwd = HostEscapeChannel(
        hostRootfs: '/run/host/rootfs',
        launcherPath: '/bin/systemd-run',
      );

      final command = withoutCwd.wrap(const <String>['/usr/bin/ll-cli', 'list']);

      expect(
        command.any((arg) => arg.startsWith('--working-directory')),
        isFalse,
      );
    });

    test('空命令被拒绝', () {
      expect(
        () => channel.wrap(const <String>[]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BridgedLinglongCliCommandBuilder', () {
    test('把宿主 ll-cli 路径与参数交给通道包装', () {
      const channel = HostEscapeChannel(
        hostRootfs: '/run/host/rootfs',
        launcherPath: '/bin/systemd-run',
      );
      final builder = BridgedLinglongCliCommandBuilder(
        channel: channel,
        hostLlCliPath: '/usr/bin/ll-cli',
      );

      final command = builder.build(const <String>['list', '--json']);

      expect(command.first, equals('/bin/systemd-run'));
      expect(command, contains('/usr/bin/ll-cli'));
      expect(command, contains('list'));
      expect(command, contains('--json'));
      // 默认必须带上英文 locale：systemd-run 不转发调用者环境。
      expect(command, contains('--setenv=LC_ALL=C.UTF-8'));
    });
  });
}
