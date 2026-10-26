import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/core/platform/cli_executor.dart';
import 'package:linglong_store/data/repositories/linglong_app_analysis_repository_impl.dart';

/// 使用上游真实字段，防止把错误响应当成零占用。
void main() {
  test('两流非空时保留stdout错误对象与stderr警告', () async {
    final repository = LinglongAppAnalysisRepositoryImpl(
      execute: (args) async => const CliOutput(
        stdout: '{"code":7,"message":"actual failure"}',
        stderr: 'warning detail',
        exitCode: 2,
      ),
    );
    await expectLater(
      repository.analyzeSize(),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          '完整诊断',
          allOf(
            contains('actual failure'),
            contains('warning detail'),
            contains('2'),
          ),
        ),
      ),
    );
  });
  const fixture =
      '{"modules":[{"id":"demo","name":"Demo","version":"1","channel":"main","module":"binary","exclusiveSize":4096,"sharedSize":8192,"logicalSize":12288,"actualSize":8192}],"calculatedLogicalSize":{"exclusiveSize":4096,"sharedSize":8192,"logicalSize":12288},"calculatedActualSize":8192,"repositoryRealSize":16384}';
  test('保留分摊与仓库真实占用的独立统计口径', () {
    final result = parseLinglongDiskUsage(fixture);
    expect(result.calculatedActualSize, 8192);
    expect(result.repositoryRealSize, 16384);
    expect(result.modules.single.sharedSize, 8192);
  });
  test('错误根对象和缺字段必须失败', () {
    for (final invalid in ['[]', '{}', '{"modules":[]}']) {
      expect(() => parseLinglongDiskUsage(invalid), throwsFormatException);
    }
  });
  test('负数字节数必须失败，零值合法', () {
    expect(
      () => parseLinglongDiskUsage(fixture.replaceAll('4096', '-1')),
      throwsFormatException,
    );
    expect(
      parseLinglongDiskUsage(
        fixture.replaceAll('8192', '0'),
      ).calculatedActualSize,
      0,
    );
  });
  test('依赖树保留 base 到 runtime 到 app 的上游方向', () {
    final nodes = parseLinglongDependencies(
      '[{"ref":"base","kind":"base","children":[{"ref":"runtime","kind":"runtime","children":[{"ref":"app","kind":"app","children":[]}]}]}]',
    );
    expect(nodes.single.kind, 'base');
    expect(nodes.single.children.single.kind, 'runtime');
    expect(nodes.single.children.single.children.single.ref, 'app');
    expect(() => parseLinglongDependencies('{}'), throwsFormatException);
  });
  test('只读命令argv遵循真实CLI契约且在后台解析', () async {
    final calls = <List<String>>[];
    final repository = LinglongAppAnalysisRepositoryImpl(
      execute: (args) async {
        calls.add(args);
        return CliOutput(
          stdout: args.last == 'size' ? fixture : '[]',
          stderr: '',
          exitCode: 0,
        );
      },
    );
    expect((await repository.analyzeSize()).repositoryRealSize, 16384);
    await repository.analyzeDepends('main:demo/1/x86_64');
    expect(calls, [
      ['--json', 'analyze', 'size'],
      ['--json', 'analyze', 'depends', 'main:demo/1/x86_64'],
    ]);
  });
  test('命令失败保留完整stderr诊断', () async {
    final repository = LinglongAppAnalysisRepositoryImpl(
      execute: (args) async => const CliOutput(
        stdout: '{}',
        stderr: 'complete diagnostic',
        exitCode: 2,
      ),
    );
    await expectLater(
      repository.analyzeSize(),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          '诊断',
          contains('complete diagnostic'),
        ),
      ),
    );
  });
}
