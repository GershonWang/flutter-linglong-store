/// 按需缓存本地分析，不随订阅或操作后失效自动扫描仓库。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../../domain/models/linglong_app_analysis.dart';
import 'application_dependency_providers.dart';
import 'linglong_cli_capabilities_provider.dart';

/// 保留刷新前的数据与独立失败诊断，避免刷新时界面闪空。
class LinglongAnalysisState<T> {
  /// 初始态没有数据，也没有正在执行的副作用。
  const LinglongAnalysisState({this.data, this.isLoading = false, this.error});

  /// 最近一次已确认快照。
  final T? data;

  /// 首载与刷新共用请求状态，界面以 data 区分。
  final bool isLoading;

  /// 完整错误内容，展示与复制均使用同一来源。
  final String? error;
}

/// 合并请求并以代数标记阻止失效期间的旧结果回写。
abstract class LinglongAnalysisController<T>
    extends StateNotifier<LinglongAnalysisState<T>> {
  /// 注入能力与只读查询，控制器不依赖具体 Data 类型。
  LinglongAnalysisController(this._enabled, this._query)
    : super(const LinglongAnalysisState());

  /// 调用时再次检查能力，防止保留旧页面绕过版本门槛。
  final bool Function() _enabled;

  /// 单次仓储读取。
  final Future<T> Function() _query;

  /// 五分钟有效期不由计时器触发，隐藏页不会工作。
  DateTime? _loadedAt;

  /// 当前代的单飞请求，失效后允许新的读取。
  Future<void>? _pending;

  /// 请求所属代数与缓存有效性分离，失效不启动第二个昂贵扫描。
  int? _pendingGeneration;

  /// 每次失效递增，已发出的进程只可完成不得更新状态。
  int _generation = 0;

  /// 读取有效缓存或合并当前请求；强制刷新保留已有快照。
  Future<void> load({bool force = false}) {
    if (!mounted) return Future.value();
    if (!_enabled()) {
      // 失效等待链也可能在下一次读取前失去能力，必须回到非加载终态。
      if (state.isLoading) {
        state = LinglongAnalysisState(data: state.data, error: state.error);
      }
      return Future.value();
    }
    if (_pending != null) {
      if (_pendingGeneration == _generation) return _pending!;
      // 只有显式读取会在旧扫描完成后接续新代，失效本身不重跑。
      state = LinglongAnalysisState(data: state.data, isLoading: true);
      return _pending!.then(
        (_) => mounted ? load(force: force) : Future<void>.value(),
      );
    }
    if (!force &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < const Duration(minutes: 5)) {
      return Future.value();
    }
    final generation = _generation;
    state = LinglongAnalysisState(data: state.data, isLoading: true);
    // 先登记请求再调用端口，同步异常也能在 finally 正确释放单飞锁。
    final completion = Completer<void>();
    _pendingGeneration = generation;
    _pending = completion.future;
    _run(
      generation,
    ).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  /// 只清除有效性，不执行查询；后续可见页面显式 load。
  void invalidate() {
    _generation++;
    _loadedAt = null;
    if (mounted) state = LinglongAnalysisState(data: state.data);
  }

  /// 严格比较代数，同时处理已关闭对话框的控制器。
  Future<void> _run(int generation) async {
    try {
      final result = await _query();
      if (mounted && generation == _generation) {
        if (_enabled()) {
          _loadedAt = DateTime.now();
          state = LinglongAnalysisState(data: result);
        } else {
          // 页面仍打开时能力可能被环境重检测撤销，结束加载但不接收新快照。
          state = LinglongAnalysisState(data: state.data);
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        state = LinglongAnalysisState(
          data: state.data,
          error: error.toString(),
        );
      }
    } finally {
      if (_pendingGeneration == generation) {
        _pending = null;
        _pendingGeneration = null;
      }
    }
  }
}

/// 全局空间快照所有者；创建控制器不会扫描。
class LinglongDiskAnalysisController
    extends LinglongAnalysisController<LinglongDiskUsage> {
  /// 空间扫描共享应用生命周期缓存。
  LinglongDiskAnalysisController(super.enabled, super.query);
}

/// 按完整 reference 隔离不同已安装版本的依赖缓存。
class LinglongAppDependenciesController
    extends LinglongAnalysisController<List<LinglongDependencyNode>> {
  /// 依赖查询使用同一失效和请求合并规则。
  LinglongAppDependenciesController(super.enabled, super.query);
}

/// 全应用单一空间缓存，仅 load 与 refresh 操作启动扫描。
final linglongDiskAnalysisProvider =
    StateNotifierProvider<
      LinglongDiskAnalysisController,
      LinglongAnalysisState<LinglongDiskUsage>
    >(
      (ref) => LinglongDiskAnalysisController(
        () => ref.read(linglongCliCapabilitiesProvider).supportsDiskAnalysis,
        () => ref.read(linglongAppAnalysisRepositoryProvider).analyzeSize(),
      ),
    );

/// 完整身份为缓存键，禁止用远端最新版本替代本地版本。
final linglongAppDependenciesProvider = StateNotifierProvider.autoDispose
    .family<
      LinglongAppDependenciesController,
      LinglongAnalysisState<List<LinglongDependencyNode>>,
      String
    >((ref, appRef) {
      // 关闭面板立即释放订阅，只保留五分钟可复用缓存，避免引用永久积累。
      final retention = ref.keepAlive();
      Timer? eviction;
      ref.onCancel(() {
        eviction?.cancel();
        eviction = Timer(const Duration(minutes: 5), retention.close);
      });
      ref.onResume(() => eviction?.cancel());
      ref.onDispose(() => eviction?.cancel());
      return LinglongAppDependenciesController(
        () => ref.read(linglongCliCapabilitiesProvider).supportsDiskAnalysis,
        () => ref
            .read(linglongAppAnalysisRepositoryProvider)
            .analyzeDepends(appRef),
      );
    });

/// 统一业务操作后同步入口：失效不会在隐藏页面启动扫描。
void invalidateLinglongAppAnalysis(Ref ref) {
  ref.read(linglongDiskAnalysisProvider.notifier).invalidate();
  ref.invalidate(linglongAppDependenciesProvider);
}
