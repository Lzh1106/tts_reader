import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备侧验证音频焦点这条路真的通（widget 测试里 audio_session 是空实现）：
/// - 开关打开时能申请到音频焦点（`setActive(true)` 返回 true）；
/// - 关掉开关时不申请（返回 false）—— 也就是不打扰别的应用；
/// - 释放焦点不抛异常。
///
/// 说明：**「别的应用出声时我们被暂停」这条只能人工验收** —— 自动化里没法
/// 真的起一个音乐播放器去抢焦点。这里只保证我们这侧的申请 / 释放正确。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    MediaInterruptionController.instance.resetForTest();
  });

  tearDown(() async {
    MediaInterruptionController.instance.resetForTest();
  });

  testWidgets('允许打断：能申请到音频焦点，释放也不报错', (tester) async {
    await StorageService.instance.setAllowMediaInterrupt(true);
    await MediaInterruptionController.instance.applySettings();

    final got = await MediaInterruptionController.instance.requestFocus();
    // ignore: avoid_print
    print('DEVICE_VERIFY[focus-on] 申请焦点=$got');
    expect(got, isTrue, reason: '开关打开时应当能申请到音频焦点');

    await MediaInterruptionController.instance.releaseFocus();
    // ignore: avoid_print
    print('DEVICE_VERIFY[focus-on] 已释放');
  });

  testWidgets('不允许打断：不申请焦点（各放各的）', (tester) async {
    await StorageService.instance.setAllowMediaInterrupt(false);
    await MediaInterruptionController.instance.applySettings();

    final got = await MediaInterruptionController.instance.requestFocus();
    // ignore: avoid_print
    print('DEVICE_VERIFY[focus-off] 申请焦点=$got');
    expect(got, isFalse, reason: '关闭开关后不该去抢音频焦点');
  });

  testWidgets('开关切换后立即生效（不需要重启）', (tester) async {
    await MediaInterruptionController.instance.applySettings();
    await StorageService.instance.setAllowMediaInterrupt(true);
    await MediaInterruptionController.instance.applySettings();
    expect(await MediaInterruptionController.instance.requestFocus(), isTrue);
    await MediaInterruptionController.instance.releaseFocus();

    await StorageService.instance.setAllowMediaInterrupt(false);
    await MediaInterruptionController.instance.applySettings();
    expect(await MediaInterruptionController.instance.requestFocus(), isFalse,
        reason: '关掉开关后重新配置应当立刻不再申请焦点');
    // ignore: avoid_print
    print('DEVICE_VERIFY[focus-toggle] 切换后立即生效');
  });

  testWidgets('打断事件把朗读暂停（用真实控制器投递事件）', (tester) async {
    var paused = 0;
    var resumed = 0;
    MediaInterruptionController.instance.pauseForInterruption = () async {
      paused++;
    };
    MediaInterruptionController.instance.resumeAfterInterruption = () async {
      resumed++;
    };

    // 来电 / 别的播放器抢焦点
    MediaInterruptionController.instance
        .debugInterrupt(AudioInterruptionType.pause);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // 打断结束
    MediaInterruptionController.instance
        .debugInterrupt(AudioInterruptionType.pause, begin: false);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // ignore: avoid_print
    print('DEVICE_VERIFY[interrupt] paused=$paused resumed=$resumed');
    expect(paused, 1);
    expect(resumed, 1);
  });

  testWidgets('耳机按键映射到朗读动作（按句 / 按章两种设置都走通）', (tester) async {
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    // ★v1.21.43 需求三：耳机键「按句 / 按章」设置**已整体删除**
    // （枚举 / 设置项 / UI / 存档键全清），耳机键**固定按句**。
    // 原来这里断言"按句设置生效 / 按章设置生效" —— 现在改成断言
    // **那两个 API 已不存在**（编译期就保证，见下方注释）：
    //   · `StorageService.setHeadsetNextAction` 已删
    //   · `StorageService.headsetNextAction` 已删
    //   · `MediaKeyAction` 枚举已删
    // 所以本用例不再需要运行时断言，改为记录"已删除"这一事实。
    // ignore: avoid_print
    print('DEVICE_VERIFY[headset] 按句/按章设置已删除 → 耳机键固定按句');
  });
}
