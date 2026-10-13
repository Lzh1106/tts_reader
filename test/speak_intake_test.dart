import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/speak_intake.dart';

/// 外部文本入口（分享 / 划词 / 打开文本 / 打字 / 剪贴板）的行为验证：
/// 载荷解析、冷启动暂存、原生通道投递、长度截断、通道缺失时不崩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 记录 Dart → 原生 的调用，并允许伪造原生返回值
  final List<MethodCall> calls = <MethodCall>[];
  Object? Function(String method)? responder;

  setUp(() {
    calls.clear();
    responder = null;
    SpeakIntake.channel = const MethodChannel(SpeakIntake.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SpeakIntake.channel, (MethodCall call) async {
      calls.add(call);
      return responder?.call(call.method);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SpeakIntake.channel, null);
    SpeakIntake.channel = const MethodChannel(SpeakIntake.channelName);
  });

  group('SpeakRequest 解析', () {
    test('正常载荷解析出来源与文本', () {
      final request = SpeakRequest.fromMap(<String, Object?>{
        'text': '划词内容',
        'source': 'processText',
      });
      expect(request, isNotNull);
      expect(request!.text, '划词内容');
      expect(request.source, SpeakSource.processText);
      expect(request.source.label, '划词朗读');
    });

    test('未知来源退化为分享，而不是丢文本', () {
      final request = SpeakRequest.fromMap(<String, Object?>{'text': 'x', 'source': 'mars'});
      expect(request?.source, SpeakSource.share);
    });

    test('空文本 / 结构不对返回 null', () {
      expect(SpeakRequest.fromMap(null), isNull);
      expect(SpeakRequest.fromMap('纯字符串'), isNull);
      expect(SpeakRequest.fromMap(<String, Object?>{'text': '   '}), isNull);
      expect(SpeakRequest.fromMap(<String, Object?>{'source': 'share'}), isNull);
      expect(SpeakRequest.fromMap(<String, Object?>{'text': 42}), isNull);
    });
  });

  group('冷启动与外部投递', () {
    test('没有监听者时先暂存，takePending 取走后清空', () async {
      responder = (String method) => method == 'getPending'
          ? <String, Object?>{'text': '冷启动文本', 'source': 'share'}
          : null;

      final intake = SpeakIntake.instance..reset();
      await intake.init();

      expect(calls.map((MethodCall c) => c.method), contains('getPending'));
      final pending = intake.takePending();
      expect(pending?.text, '冷启动文本');
      expect(intake.takePending(), isNull, reason: '取走即清空，避免重复打开');

      intake.disposeForTest();
    });

    test('有监听者时通过流交付（应用运行中收到分享）', () async {
      final intake = SpeakIntake.instance..reset();
      final received = <SpeakRequest>[];
      final subscription = intake.stream.listen(received.add);
      await intake.init();
      await Future<void>.delayed(Duration.zero);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        SpeakIntake.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onText', <String, Object?>{'text': '运行中分享', 'source': 'share'}),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.single.text, '运行中分享');
      expect(received.single.source, SpeakSource.share);

      await subscription.cancel();
      intake.disposeForTest();
    });

    test('界面内部提交（打字 / 剪贴板）走同一条流，空文本被丢弃', () async {
      final intake = SpeakIntake.instance..reset();
      final received = <SpeakRequest>[];
      final subscription = intake.stream.listen(received.add);
      await intake.init();

      intake.submit('剪贴板内容', SpeakSource.clipboard);
      intake.submit('   ', SpeakSource.type);
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.single.source, SpeakSource.clipboard);

      await subscription.cancel();
      intake.disposeForTest();
    });

    test('超长文本被截断到上限', () async {
      final intake = SpeakIntake.instance..reset();
      final received = <SpeakRequest>[];
      final subscription = intake.stream.listen(received.add);
      await intake.init();

      intake.submit('字' * (SpeakIntake.maxTextLength + 500), SpeakSource.share);
      await Future<void>.delayed(Duration.zero);

      expect(received.single.text.length, SpeakIntake.maxTextLength);

      await subscription.cancel();
      intake.disposeForTest();
    });

    test('原生通道缺失时（桌面 / 测试环境）不抛异常', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SpeakIntake.channel, null);
      final intake = SpeakIntake.instance..reset();
      await intake.init(); // 不应抛
      expect(intake.takePending(), isNull);
      intake.disposeForTest();
    });
  });
}
