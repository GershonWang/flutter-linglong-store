/// 保障清理偏好只扩展类型化布尔字段，不扩大特权 helper 的命令边界。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linglong_store/core/platform/privileged_helper/privileged_helper_protocol.dart';

/// 验证关闭清理在两种任务中都透传，默认请求保持旧 helper 兼容。
void main() {
  test('默认请求不增加协议字段', () {
    final decoded =
        jsonDecode(
              const PrivilegedHelperStartRequest(
                requestId: 'task',
                operation: PrivilegedHelperOperation.install,
                appId: 'org.example.demo',
                force: false,
              ).encode(),
            )
            as Map<String, dynamic>;
    expect(decoded.containsKey('noAutoPrune'), isFalse);
  });
  test('安装与升级均传递清理控制', () {
    for (final operation in PrivilegedHelperOperation.values) {
      final decoded =
          jsonDecode(
                PrivilegedHelperStartRequest(
                  requestId: 'task',
                  operation: operation,
                  appId: 'org.example.demo',
                  force: false,
                  noAutoPrune: true,
                ).encode(),
              )
              as Map<String, dynamic>;
      expect(decoded['noAutoPrune'], isTrue);
      if (operation == PrivilegedHelperOperation.update) {
        expect(decoded.containsKey('force'), isFalse);
      }
    }
  });
}
