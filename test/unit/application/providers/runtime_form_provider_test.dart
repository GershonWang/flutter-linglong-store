import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:linglong_store/application/providers/runtime_form_provider.dart';

void main() {
  test('默认按常规宿主安装处理，保证非玲珑形态行为不变', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(linglongRuntimeFormProvider),
      LinglongRuntimeForm.hostInstalled,
    );
    expect(container.read(installCancelEnabledProvider), isTrue);
    expect(container.read(passwordFreeInstallSupportedProvider), isTrue);
  });

  test('玲珑容器形态下关闭取消与免密能力', () {
    final container = ProviderContainer(
      overrides: [
        linglongRuntimeFormProvider.overrideWithValue(
          LinglongRuntimeForm.linglongContainer,
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(installCancelEnabledProvider), isFalse);
    expect(container.read(passwordFreeInstallSupportedProvider), isFalse);
  });
}
