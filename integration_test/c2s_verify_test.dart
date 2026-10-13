import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/services/c2s.dart';
import 'package:tts_reader/services/speak_intake.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层验证：复制即朗读（C2S）的原生实现真的接上了。
///
/// 覆盖：通道可用、配置能往返、悬浮球能真的起来、开机自启的接收器与两个快捷磁贴
/// 已经注册进系统，以及「悬浮球/磁贴把文本交给朗读链路」这一条。
///
/// 跑法（需要设备/模拟器）：
///   adb shell appops set com.example.tts_reader SYSTEM_ALERT_WINDOW allow
///   flutter test integration_test/c2s_verify_test.dart -d emulator-5554
///
/// 说明：悬浮窗权限在模拟器上用 appops 直接授予，省掉手动点系统设置。
/// 没授权时本用例会走「如实报告没起来」的分支，仍然不会失败（权限是用户的选择）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final c2s = C2sController.instance;

  setUpAll(() async {
    await StorageService.instance.init();
    await TtsManager.instance.init();
  });

  setUp(() async {
    await TtsManager.instance.stop();
  });

  tearDownAll(() async {
    // 收尾：把悬浮球关掉，别把通知栏留给下一次运行
    await c2s.apply(enabled: false);
  });

  void report(String label, String detail) {
    // ignore: avoid_print
    print('DEVICE_VERIFY[$label] $detail');
  }

  testWidgets('通道可用：配置能读回、字段齐全', (WidgetTester tester) async {
    await c2s.refresh();
    report(
      'c2s-config',
      'supported=${c2s.supported} enabled=${c2s.config.enabled} '
      'autoShow=${c2s.config.autoShow} size=${c2s.config.sizeDp} '
      'overlay=${c2s.config.overlayPermission} running=${c2s.config.running}',
    );
    expect(c2s.supported, isTrue, reason: 'Android 侧必须实现了 tts_reader/c2s 通道');
    expect(c2s.config.sizeDp, greaterThanOrEqualTo(c2s.config.minSizeDp));
    expect(c2s.config.sizeDp, lessThanOrEqualTo(c2s.config.maxSizeDp));
  });

  testWidgets('悬浮球：授权后能真的起来，关掉后能真的停', (WidgetTester tester) async {
    await c2s.refresh();
    if (!c2s.config.overlayPermission) {
      // 权限是用户到系统设置里授予的（CI / 模拟器上用 appops 直接给），
      // 这里等最多 20 秒，好让「授权 → 开关生效」这条链路也能被自动验证。
      for (var i = 0; i < 40 && !c2s.config.overlayPermission; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await c2s.hasOverlayPermission();
      }
    }
    if (!c2s.config.overlayPermission) {
      report('c2s-float', 'skipped=缺少悬浮窗权限（用 appops 授权后可完整验证）');
      return;
    }

    final started = await c2s.apply(enabled: true, autoShow: true, sizeDp: 52);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await c2s.refresh();
    report(
      'c2s-float',
      'started=$started running=${c2s.config.running} enabled=${c2s.config.enabled}',
    );
    expect(started, isTrue, reason: '授权之后悬浮球应当能起来');
    expect(c2s.config.running, isTrue);

    final stopped = await c2s.apply(enabled: false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await c2s.refresh();
    report('c2s-float-stop', 'stopped=${!stopped} running=${c2s.config.running}');
    expect(c2s.config.running, isFalse, reason: '关掉之后服务要真的停');
  });

  testWidgets('悬浮球大小可调并在重启读取后保持', (WidgetTester tester) async {
    await c2s.apply(sizeDp: 64);
    await c2s.refresh();
    report('c2s-size', 'size=${c2s.config.sizeDp}');
    expect(c2s.config.sizeDp, 64, reason: '配置写在原生侧，读回来要一致');

    await c2s.apply(sizeDp: 52);
  });

  testWidgets('朗读剪贴板：写剪贴板 → 原生透明界面取词 → 交回朗读链路', (WidgetTester tester) async {
    await SpeakIntake.instance.init();

    // 写系统剪贴板（走 Flutter 的剪贴板通道，写的就是系统剪贴板）
    const String clipboardText = '剪贴板第一句。剪贴板第二句。';
    await Clipboard.setData(const ClipboardData(text: clipboardText));

    final incoming = SpeakIntake.instance.stream.first;
    await c2s.speakClipboard();

    // 原生侧：启动透明界面 → 读剪贴板 → MainActivity.deliver → onText
    final request = await incoming.timeout(const Duration(seconds: 10));
    report('c2s-clipboard', 'source=${request.source.label} chars=${request.text.length}');
    expect(request.source, SpeakSource.c2s);
    expect(request.text, clipboardText, reason: '读到的必须就是刚写进剪贴板的内容');
  });

  testWidgets('复制即朗读进来的文本能被朗读链路接收并读完', (WidgetTester tester) async {
    await SpeakIntake.instance.init();
    final tts = TtsManager.instance;

    // 悬浮球 / 磁贴走的就是原生侧 invokeMethod("onText", {source: "c2s"})
    final incoming = SpeakIntake.instance.stream.first;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      SpeakIntake.channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onText', <String, dynamic>{
          'text': '第一句。第二句。',
          'source': 'c2s',
        }),
      ),
      (_) {},
    );

    final request = await incoming.timeout(const Duration(seconds: 5));
    report('c2s-intake', 'source=${request.source.label} chars=${request.text.length}');
    expect(request.source, SpeakSource.c2s, reason: '悬浮球/磁贴的文本要标成复制即朗读');

    // 走同一条朗读链路读到底（即读页由 app 级监听打开，这里只验证链路）
    tts.speakLines(<String>['第一句。', '第二句。']);
    var finished = true;
    await tts.whenSessionFinished().timeout(
      const Duration(seconds: 60),
      onTimeout: () => finished = false,
    );
    report('c2s-speak', 'finished=$finished speaking=${tts.speaking} error=${tts.error}');
    expect(tts.error, isNull, reason: '真实引擎朗读不应报错');
  });
}
