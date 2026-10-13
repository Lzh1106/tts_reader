import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **借声残留**的回归（v1.21.40）
///
/// ## 症状（真机日志满屏重复）
/// ```
/// 借声[退出] previous=false speaking=true hasSession=true doc=null
/// 借声[进入] previous=false speaking=true doc=null hasSession=true
/// ```
/// PDF 朗读停了之后，TtsManager 身上留着一个 `doc=null` 的**假会话**：
/// 文档库控制栏的碟片走了又回来，点播放什么都不读。
///
/// ## 根因
/// PDF 是**借** `speakText` 发声的，每读一句都会把
/// `_plainMode = true` + `_lines = [这一句]` 写进 TtsManager。
/// 而 `speakForOther` 的 `finally` 里那道清理带 `!_speaking` 判据 ——
/// **PDF 每读完一句、body 返回时声音还在响**（`_speaking` 仍为 true），
/// 判据不成立，于是**从不执行**。原注释写「等那一次借完自己清」，
/// 但代码里没有任何地方安排这次清理。
///
/// ## 为什么单独一个文件
/// `borrow_audio_session_test.dart` 的 setup 用的是**刻意挂住 60 秒**的引擎
/// （为了稳定停在"借声中"这个状态），走不到"读完收尾"那条路。
/// 这条需要**会正常读完**的引擎，所以单独放。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    TtsManager.instance.resetSessionForTest();
    TtsManager.instance.resetTimeouts();
  });

  tearDown(() async {
    await TtsManager.instance.stop();
    TtsManager.instance.resetTimeouts();
    TtsManager.instance.resetSessionForTest();
  });

  Future<void> waitFor(bool Function() cond, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('借声读完后不留下 doc=null 的假会话（hasSession 必须回落 false）', () async {
    final manager = TtsManager.instance;
    await manager.registerEngine(_FinishingEngine(), makeActive: true);

    // 前置：借声之前没有自己的会话 —— 这正是 PDF 那条路的真实状态
    expect(manager.hasSession, isFalse, reason: '前置：起点不该有会话');

    // 借声：body 只负责"发起朗读"，**等 `_speaking` 真的起来**就返回
    //
    // ⚠️ 这个等待是复现的关键，不是凑时间：
    // 真实 bug 的成因是「body 返回时声音还在响（`_speaking=true`）」→
    // `speakForOther` 的 `finally` 里那道带 `!_speaking` 判据的清理**不执行**。
    // 若不等它起来就返回，测的就是"读完才返回"那条路（旧代码也能过），等于没测。
    await manager.speakForOther<void>(() async {
      manager.speakText('借来的一句');
      await waitFor(() => manager.speaking, const Duration(seconds: 2));
      // ignore: avoid_print
      print('DEVICE_VERIFY[borrow-leftover] body 返回时 speaking=${manager.speaking} '
          'hasSession=${manager.hasSession}');
    });
    expect(manager.isBorrowedForOther, isFalse, reason: '借声标记要复位');

    // 等这一句真的读完（收尾发生在读完那一刻）
    await waitFor(() => !manager.speaking, const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // ignore: avoid_print
    print('DEVICE_VERIFY[borrow-leftover] 读完后 hasSession=${manager.hasSession} '
        'speaking=${manager.speaking}');
    expect(manager.hasSession, isFalse,
        reason: '借声读完后不该留下假会话 —— '
            '修前 `_lines` 残留让 hasSession 恒为 true，'
            '控制栏碟片走了又回来、点播放什么都不读');
  });

  test('用户的纯文本队列不受影响（只有"借来的"才清）', () async {
    final manager = TtsManager.instance;
    await manager.registerEngine(_FinishingEngine(), makeActive: true);

    // 用户入口（网页朗读 / 复制即朗读）：这里必须**不**被当成借声清掉
    manager.speakLines(<String>['一', '二', '三']);
    expect(manager.hasSession, isTrue, reason: '用户队列一开始就该有会话');

    // 读完第一条之后仍在播（队列还有两条）→ hasSession 必须保持 true
    await waitFor(() => manager.progressIndex >= 1, const Duration(seconds: 3));
    expect(manager.hasSession, isTrue,
        reason: '用户自己的队列不能被当成"借声残留"清掉');
  });

  test('连续借声多次都幂等（每次都清干净，不会越攒越多）', () async {
    final manager = TtsManager.instance;
    await manager.registerEngine(_FinishingEngine(), makeActive: true);

    for (var i = 0; i < 3; i++) {
      await manager.speakForOther<void>(() async {
        manager.speakText('第 $i 句');
        await waitFor(() => manager.speaking, const Duration(seconds: 2));
      });
      await waitFor(() => !manager.speaking, const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(manager.hasSession, isFalse,
          reason: '第 $i 次借声读完后仍应是"没有会话"（幂等）');
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[borrow-leftover] 连借 3 次后 hasSession=${manager.hasSession}');
  });
}

/// 会**正常读完**的假引擎：40ms 后回调完成
///
/// 与 `borrow_audio_session_test.dart` 里那个"挂住不返回"的引擎刻意不同 ——
/// 那条路测的是"借声期间被打断"，这条测的是"借声正常读完之后"。
class _FinishingEngine with SyntheticTtsEngine implements TtsEngine {
  void Function()? _onComplete;

  @override
  String get id => 'borrow-finishing';
  @override
  String get displayName => '假引擎（读完即回调）';
  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {}
  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[];
  @override
  Future<void> setVoice(String voiceId) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<void> speak(String text) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _onComplete?.call();
  }

  @override
  void setCompletionHandler(void Function()? handler) {
    _onComplete = handler;
  }
}
