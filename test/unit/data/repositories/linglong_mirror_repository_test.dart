/// 验证镜像配置使用上游真实字段，避免未知状态被当成关闭。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/core/platform/cli_executor.dart';
import 'package:linglong_store/data/repositories/linglong_cli_repository_impl.dart';
import 'package:linglong_store/domain/models/linglong_env_check_result.dart';

/// 使用结构化配置与命令记录验证镜像契约，不修改开发机仓库。
void main() {
  test('仓库模型保留上游镜像字段和地区', () {
    final repo = LinglongRepoInfo.fromJson({
      'name': 'stable',
      'url': 'https://repo.example.com',
      'mirror_enabled': true,
      'region': 'CN',
    });
    expect(repo.toJson()['mirror_enabled'], isTrue);
    expect(repo.toJson()['region'], 'CN');
  });

  test('仓库 JSON 读取保留镜像状态而不丢字段', () async {
    final repository = _repository(
      const CliOutput(
        stdout:
            '{"defaultRepo":"stable","version":2,"repos":[{"name":"stable","url":"https://repo.example.com","priority":0,"mirror_enabled":true,"region":"CN"}]}',
        stderr: '',
        exitCode: 0,
      ),
    );
    final config = await repository.getRepositoryConfig();
    expect(config.repos.single.toJson()['mirror_enabled'], isTrue);
    expect(config.repos.single.toJson()['region'], 'CN');
  });
  test('地区参数仅在明确开启指定地区时追加，自动和关闭均省略', () async {
    final calls = <List<String>>[];
    final repository = _repository(
      const CliOutput(stdout: '', stderr: '', exitCode: 0),
      calls: calls,
    );
    await repository.setRepositoryMirror('stable', enabled: true, region: 'CN');
    await repository.setRepositoryMirror(
      'stable',
      enabled: false,
      region: 'US',
    );
    await repository.setRepositoryMirror('stable', enabled: true);
    expect(calls, [
      ['repo', 'enable-mirror', 'stable', '--region', 'CN'],
      ['repo', 'disable-mirror', 'stable'],
      ['repo', 'enable-mirror', 'stable'],
    ]);
  });

  test('不安全地区不能通过直接 Repository 调用进入上游 URL', () {
    final calls = <List<String>>[];
    final repository = _repository(
      const CliOutput(stdout: '', stderr: '', exitCode: 0),
      calls: calls,
    );
    for (final value in ['', 'CN US', 'CN&region=US', 'CN?x=1', '--region']) {
      expect(
        () => repository.setRepositoryMirror(
          'stable',
          enabled: true,
          region: value,
        ),
        throwsArgumentError,
      );
    }
    expect(calls, isEmpty);
  });

  test('文本回退无法确认开关及地区', () async {
    final repository = _repository(
      const CliOutput(stdout: 'not json', stderr: '', exitCode: 0),
      textOutput: const CliOutput(
        stdout:
            'Default: stable\nName    Url                       Alias   Priority\nstable  https://repo.example.com  stable  0\n',
        stderr: '',
        exitCode: 0,
      ),
    );
    final repo = (await repository.getRepositoryConfig()).repos.single;
    expect(repo.isMirrorEnabled, isNull);
    expect(repo.region, isNull);
  });
}

/// 注入固定只读输出，所有外部进程均由空实现隔离。
LinglongCliRepositoryImpl _repository(
  CliOutput output, {
  List<List<String>>? calls,
  CliOutput? textOutput,
}) {
  return LinglongCliRepositoryImpl.withExecutor(
    execute:
        (
          args, {
          timeout = const Duration(seconds: 30),
          processId,
          locale,
        }) async {
          calls?.add(List.of(args));
          return args.first == 'repo' &&
                  args.last == 'show' &&
                  textOutput != null
              ? textOutput
              : output;
        },
    executeWithProgressAndProcess:
        (args, {processId, locale, onProcessCreated}) => const Stream.empty(),
    cancelWithSystemKill: (processId, {required pid, force = false}) async =>
        false,
  );
}
