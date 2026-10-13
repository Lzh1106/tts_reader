import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 外观设置的设备侧验证（动态取色 + 背景图）。
///
/// 说明：「启动图标切换」功能**已按要求删除**（不同 ROM 上表现不一致），
/// 依赖 `activity-alias` 的那套用例一并移除。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('外观设置持久化：动态取色 + 背景透明度', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    await StorageService.instance.setUseDynamicColor(true);
    await StorageService.instance.setBackgroundImageOpacity(0.62);
    // ignore: avoid_print
    print('DEVICE_VERIFY[appearance] dynamic='
        '${StorageService.instance.useDynamicColor} '
        'opacity=${StorageService.instance.backgroundImageOpacity}');

    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.useDynamicColor, isTrue);
    expect(StorageService.instance.backgroundImageOpacity, closeTo(0.62, 0.001));

    // 收尾：恢复默认，免得影响后续用例
    await StorageService.instance.setUseDynamicColor(false);
    await StorageService.instance.setBackgroundImageOpacity(0.35);
  });
}
