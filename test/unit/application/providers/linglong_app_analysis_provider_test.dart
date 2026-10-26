import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/application/providers/application_dependency_providers.dart';
import 'package:linglong_store/application/providers/linglong_app_analysis_provider.dart';
import 'package:linglong_store/application/providers/linglong_cli_capabilities_provider.dart';
import 'package:linglong_store/domain/models/linglong_app_analysis.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';
import 'package:linglong_store/domain/repositories/linglong_app_analysis_repository.dart';

/// 可控制真实异步时序的只读仓储替身。
class _Repository implements LinglongAppAnalysisRepository {
  final requests = <Completer<LinglongDiskUsage>>[];
  @override
  Future<LinglongDiskUsage> analyzeSize() {
    final request = Completer<LinglongDiskUsage>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<LinglongDependencyNode>> analyzeDepends(String appRef) async =>
      [];
}

/// 空快照仍保留完整统计口径。
LinglongDiskUsage _usage(int size) => LinglongDiskUsage(
  modules: [],
  calculatedExclusiveSize: 0,
  calculatedSharedSize: 0,
  calculatedLogicalSize: 0,
  calculatedActualSize: size,
  repositoryRealSize: size,
);
void main() {
  test('失效等待链中能力撤销仍结束加载且不重扫', () async {
    var enabled = true;
    final repository = _Repository();
    final controller = LinglongDiskAnalysisController(
      () => enabled,
      repository.analyzeSize,
    );
    addTearDown(controller.dispose);
    final old = controller.load();
    controller.invalidate();
    final fresh = controller.load();
    enabled = false;
    repository.requests.single.complete(_usage(1));
    await Future.wait([old, fresh]);
    expect(controller.state.data, isNull);
    expect(controller.state.isLoading, isFalse);
    expect(repository.requests.length, 1);
  });
  test('执行中能力被撤销时不存新快照且结束加载状态', () async {
    var enabled = true;
    final repository = _Repository();
    final controller = LinglongDiskAnalysisController(
      () => enabled,
      repository.analyzeSize,
    );
    addTearDown(controller.dispose);
    final pending = controller.load();
    enabled = false;
    repository.requests.single.complete(_usage(1));
    await pending;
    expect(controller.state.data, isNull);
    expect(controller.state.isLoading, isFalse);
  });
  test('刷新保留旧快照，单项失败保留完整诊断', () async {
    final repository = _Repository();
    final controller = LinglongDiskAnalysisController(
      () => true,
      repository.analyzeSize,
    );
    addTearDown(controller.dispose);
    final first = controller.load();
    repository.requests.single.complete(_usage(1));
    await first;
    final refresh = controller.load(force: true);
    expect(controller.state.data?.calculatedActualSize, 1);
    expect(controller.state.isLoading, isTrue);
    repository.requests.last.completeError(StateError('full diagnostic'));
    await refresh;
    expect(controller.state.data?.calculatedActualSize, 1);
    expect(controller.state.error, contains('full diagnostic'));
    expect(controller.state.isLoading, isFalse);
  });
  test('同步查询异常不会把已结束的请求永久保留', () async {
    var calls = 0;
    final controller = LinglongDiskAnalysisController(() => true, () {
      calls++;
      throw StateError('query unavailable');
    });
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.state.error, contains('query unavailable'));
    await controller.load(force: true);
    expect(calls, 2);
  });
  test('按需加载合并请求，并复用五分钟快照', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
        linglongCliCapabilitiesProvider.overrideWithValue(
          LinglongCliCapabilities.fromVersion('1.14.0'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(linglongDiskAnalysisProvider.notifier);
    expect(repository.requests, isEmpty);
    final first = controller.load();
    final second = controller.load();
    expect(repository.requests.length, 1);
    repository.requests.single.complete(_usage(1));
    await Future.wait([first, second]);
    await controller.load();
    expect(repository.requests.length, 1);
    expect(
      container.read(linglongDiskAnalysisProvider).data?.calculatedActualSize,
      1,
    );
  });
  test('失效阻止旧结果回写，下一次按需加载启动新请求', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
        linglongCliCapabilitiesProvider.overrideWithValue(
          LinglongCliCapabilities.fromVersion('1.14.0'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(linglongDiskAnalysisProvider.notifier);
    final old = controller.load();
    controller.invalidate();
    expect(repository.requests.length, 1);
    final fresh = controller.load();
    expect(repository.requests.length, 1, reason: '旧扫描结束前不得启动第二个仓库遍历');
    repository.requests.first.complete(_usage(1));
    await old;
    expect(container.read(linglongDiskAnalysisProvider).data, isNull);
    repository.requests.last.complete(_usage(2));
    await fresh;
    expect(
      container.read(linglongDiskAnalysisProvider).data?.calculatedActualSize,
      2,
    );
  });
  test('低版本禁止执行分析命令', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        linglongAppAnalysisRepositoryProvider.overrideWithValue(repository),
        linglongCliCapabilitiesProvider.overrideWithValue(
          LinglongCliCapabilities.fromVersion('1.13.0'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(linglongDiskAnalysisProvider.notifier).load();
    expect(repository.requests, isEmpty);
  });
}
