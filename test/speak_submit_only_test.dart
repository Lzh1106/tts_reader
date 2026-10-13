import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/tts/system_tts_engine.dart';

/// 层 1 验证：`SystemTtsEngine.speak()` **不再把「提交成功」当成「读完」**。
///
/// 做法：把 `flutter_tts` 的方法通道 mock 掉，让它按真机实测的行为返回
/// （`speak` 立刻返回 1 / 或返回 0 表示被丢弃），然后**手动**投递引擎的完成
/// 回调（等价于 `UtteranceProgressListener.onDone` → 插件发 `speak.onComplete`），
/// 断言「回调到之前 speak() 不能返回」。
///
/// 真机根因（flutter_tts 4.0.2 android 侧）：
///   · `speak` 分支：`if (speaking) { if (QUEUE_FLUSH) { result.success(0); return } }`
///   · `stop` 分支：`speakResult!!.success(0)`
/// 这两条都会让插件那个 Future 立刻完成；旧实现用 `Future.any([done, 插件 Future])`
/// 与它竞速，于是把「提交/被丢弃」当成了「读完」→ 位置疯狂推进。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('flutter_tts');
  final List<String> calls = <String>[];

  /// 每次 `speak` 调用返回什么（按顺序取，取完就用最后一个）。
  late List<dynamic> speakResponses;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'speak') {
        final dynamic value =
            speakResponses.length > 1 ? speakResponses.removeAt(0) : speakResponses.first;
        return value;
      }
      return 1; // awaitSpeakCompletion / setSpeechRate / ... 一律成功
    });
  }

  /// 投递一条「来自平台」的调用（模拟引擎回调）。
  Future<void> emit(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (ByteData? _) {},
    );
  }

  setUp(() {
    calls.clear();
    speakResponses = <dynamic>[1];
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('提交立刻返回 1（未等读完）→ speak() 必须继续等完成回调', () async {
    final engine = SystemTtsEngine();
    var completed = false;
    final Future<void> future =
        engine.speak('这一句足够长，用来验证提交即返回不会被当成读完。')
          ..then((_) => completed = true);

    // 提交后给足时间：旧实现（Future.any）在这里早就「读完」了
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(calls.contains('speak'), isTrue, reason: '必须真的提交过');
    expect(completed, isFalse, reason: '插件立刻返回 ≠ 读完，绝不能放行');

    // 引擎真正读完 → 完成回调
    await emit('speak.onComplete');
    await future;
    expect(completed, isTrue, reason: '完成回调到了才允许返回');
    await engine.dispose();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('提交被丢弃（返回 0）→ 不当作读完，并且会重投', () async {
    speakResponses = <dynamic>[0, 1]; // 第一次被丢弃，重投成功
    final engine = SystemTtsEngine();
    var completed = false;
    final Future<void> future = engine.speak('被打断之后紧接着的这一句，用来验证重投。')
      ..then((_) => completed = true);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(completed, isFalse, reason: '被丢弃不是读完');
    expect(calls.where((String c) => c == 'speak').length, greaterThanOrEqualTo(2),
        reason: '被丢弃后必须重投，而不是当成读完或直接失败');

    await emit('speak.onComplete');
    await future;
    expect(completed, isTrue);
    await engine.dispose();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('一直丢弃（重投用尽）→ 明确失败，而不是静默滑过去', () async {
    speakResponses = <dynamic>[0]; // 永远被丢弃
    final engine = SystemTtsEngine();
    await expectLater(
      engine.speak('这一句会一直提交失败，用来验证最终会报错。'),
      throwsA(isA<StateError>()),
    );
    await engine.dispose();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('反向：正常读完（500ms 后回调一次）→ speak() 正常返回、不抛错', () async {
    final engine = SystemTtsEngine();
    var completed = false;
    final Future<void> future = engine.speak('这一句按 500ms 的真实节奏读完。')
      ..then((_) => completed = true);

    // 提交后 300ms 还不该完成
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(completed, isFalse, reason: '还没到 500ms，不许提前放行');
    // 到点后引擎回调完成
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await emit('speak.onComplete');
    await future;
    expect(completed, isTrue, reason: '正常读完必须正常返回（路径 B 修法不能把正常也判成失败）');
    await engine.dispose();
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('stop() 打断 → speak() 立刻放行（被打断要尽快完成，不算失败）', () async {
    final engine = SystemTtsEngine();
    var completed = false;
    final Future<void> future = engine.speak('这一句会被打断，用来验证打断路径仍然放行。')
      ..then((_) => completed = true);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(completed, isFalse);
    await engine.stop();
    await future;
    expect(completed, isTrue, reason: '被打断的朗读必须尽快放行，不能挂住主循环');
    await engine.dispose();
  }, timeout: const Timeout(Duration(seconds: 15)));
}
