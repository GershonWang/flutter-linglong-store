import 'package:flutter_test/flutter_test.dart';

import 'package:linglong_store/core/logging/app_logger.dart';
import 'package:linglong_store/core/platform/cli_executor.dart';
import 'package:linglong_store/core/platform/linglong_cli_command.dart';

/// 固定返回同一条命令的测试构造器。
///
/// 用途是证明 [CliExecutor] 真的经过命令构造器：如果它仍自行拼 `'ll-cli'`，
/// 下面的用例就会因为找不到该命令而失败。
class _FixedCommandBuilder implements LinglongCliCommandBuilder {
  const _FixedCommandBuilder(this.command);

  final List<String> command;

  @override
  List<String> build(List<String> args) => command;
}

void main() {
  // CliExecutor 会记录命令日志，日志器必须先初始化（与其它调用 CliExecutor 的
  // 测试一致）。
  setUpAll(AppLogger.init);

  group('LocalLinglongCliCommandBuilder', () {
    test('在参数前补上 ll-cli 并保持顺序', () {
      const builder = LocalLinglongCliCommandBuilder();

      expect(
        builder.build(<String>['list', '--json']),
        equals(<String>['ll-cli', 'list', '--json']),
      );
    });

    test('无参数时只返回命令名', () {
      const builder = LocalLinglongCliCommandBuilder();

      expect(builder.build(const <String>[]), equals(<String>['ll-cli']));
    });
  });

  group('CliExecutor 命令构造器接缝', () {
    tearDown(() {
      // 静态接缝是全局状态，用例结束必须还原，避免污染其它测试。
      CliExecutor.configureCommandBuilder(
        const LocalLinglongCliCommandBuilder(),
      );
    });

    test('execute 使用构造器给出的命令', () async {
      CliExecutor.configureCommandBuilder(
        const _FixedCommandBuilder(<String>['/bin/echo', 'from-builder']),
      );

      final output = await CliExecutor.execute(const <String>['ignored']);

      expect(output.exitCode, equals(0));
      expect(output.stdout.trim(), equals('from-builder'));
    });
  });
}
