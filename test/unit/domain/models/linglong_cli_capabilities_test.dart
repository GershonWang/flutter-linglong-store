/// 验证新增命令门槛，防止旧 CLI 收到不支持的参数或出现无效入口。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/domain/models/linglong_cli_capabilities.dart';

/// 覆盖真实版本输出及发行版构建后缀，不用商店版本代替系统 CLI 版本。
void main() {
  test('1.14.0 是新能力的最低正式版本', () {
    expect(
      LinglongCliCapabilities.fromVersion(
        'linyaps CLI version 1.13.0',
      ).supportsDiskAnalysis,
      isFalse,
    );
    expect(
      LinglongCliCapabilities.fromVersion(
        'linyaps CLI version 1.14.0',
      ).supportsDiskAnalysis,
      isTrue,
    );
    expect(
      LinglongCliCapabilities.fromVersion(
        '1.14.2+distribution',
      ).supportsAutoPruneControl,
      isTrue,
    );
    expect(
      LinglongCliCapabilities.fromVersion(
        '1.15.0-dev+abc',
      ).supportsMirrorRegion,
      isTrue,
    );
    expect(
      LinglongCliCapabilities.fromVersion('1.14.0-rc1').supportsDiskAnalysis,
      isFalse,
    );
  });

  test('未知版本保守关闭全部新增能力', () {
    for (final version in <String?>[null, '', 'unknown', 'garbage 1.14 text']) {
      final capabilities = LinglongCliCapabilities.fromVersion(version);
      expect(capabilities.supportsDiskAnalysis, isFalse);
      expect(capabilities.supportsAutoPruneControl, isFalse);
      expect(capabilities.supportsMirrorRegion, isFalse);
    }
  });
}
