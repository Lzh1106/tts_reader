import 'package:audio_session/audio_session.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 假引擎：**开口后一直挂着**，直到被 `pause()` / `stop()` 打断才放行。
///
/// 这是真机「微信通知打断」那一刻的真实形态：引擎正在出声（`speak` 的 Future
/// 还没返回），我们这边 `pause()` 把它停掉，随后**不会再有完成回调**。
/// 用它才能验出"调了 resume 但什么都没发生"这类 bug。
class _HangingEngine with SyntheticTtsEngine implements TtsEngine {
  final List<String> spoken = <String>[];
  Completer<void>? _hang;

  @override
  String get id => 'hanging-engine';

  @override
  String get displayName => '假引擎（挂住不回调）';

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

  /// 记下这次开口，然后**挂住不返回**（真引擎就是这样的：读完才返回）
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    _hang = Completer<void>();
    await _hang!.future;
  }

  void _release() {
    final hang = _hang;
    _hang = null;
    if (hang != null && !hang.isCompleted) hang.complete();
  }

  /// 被打断：真引擎在 `pause()` 里放行挂着的等待者（见 `SystemTtsEngine.pause`）
  @override
  Future<void> pause() async => _release();

  @override
  Future<void> stop() async => _release();

  /// 这个假引擎不需要完成回调：它靠 `pause()` / `stop()` 放行
  /// （真引擎的 `pause()` 也正是这样唤醒挂着的等待者的）。
  @override
  void setCompletionHandler(void Function()? handler) {}

  @override
  Future<void> dispose() async => _release();
}

/// 「允许其它媒体打断朗读」+「耳机按键行为」：
/// - 两项设置的默认值与落盘；
/// - 打断事件的处理（pause 时暂停、结束时自动继续；用户自己暂停过就不自动继续）；
/// - 设置页上的开关 / 单选确实在，且改动落到 StorageService。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    MediaInterruptionController.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
  });

  tearDown(() {
    MediaInterruptionController.instance.resetForTest();
    TtsManager.instance.resetSessionForTest();
  });

  group('设置项默认值与落盘', () {
    // ★v1.21.43 需求三：耳机「按句 / 按章」设置**已整体删除** ——
    // 枚举 `MediaKeyAction`、`headsetNextAction` getter、`setHeadsetNextAction`
    // 全都不存在了（编译期即保证），耳机键**固定按句**。
    // 原来这一组有 4 条用例围着它转，现在只剩"允许被打断"这一项 + 一条**反向断言**。
    test('默认允许被打断', () async {
      expect(StorageService.instance.allowMediaInterrupt, isTrue,
          reason: '默认应当允许其它媒体打断朗读');
    });

    test('「允许被打断」能落盘并读回', () async {
      await StorageService.instance.setAllowMediaInterrupt(false);

      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      // ignore: avoid_print
      print('DEVICE_VERIFY[media-settings] '
          'allow=${StorageService.instance.allowMediaInterrupt}');
      expect(StorageService.instance.allowMediaInterrupt, isFalse);
    });

    test('★需求三：旧的耳机按键存档键会被清掉（不留幽灵值）', () async {
      // 模拟"用户设备上还留着旧版本写的存档"
      SharedPreferences.setMockInitialValues(<String, Object>{
        'audio_headset_next_action': 'chapter',
        'audio_allow_media_interrupt': true,
      });
      StorageService.instance.resetForTest();
      await StorageService.instance.init();

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('audio_headset_next_action'), isNull,
          reason: '★启动时必须把这个已废弃的键删掉 —— '
              '留着它将来若有人把枚举加回来，会读到一个"幽灵选择"');
      // 其它设置不受影响
      expect(StorageService.instance.allowMediaInterrupt, isTrue);
    });

    test('resetForTest 把「允许被打断」恢复默认', () async {
      await StorageService.instance.setAllowMediaInterrupt(false);
      StorageService.instance.resetForTest();
      expect(StorageService.instance.allowMediaInterrupt, isTrue);
    });
  });

  group('打断事件处理', () {
    // ---- v1.21.39：这条曾被我改错，用反例钉住，别再"顺手改成 false" ----
    test('⚠️ 必须允许"被 duck 时暂停"，否则视频打断会失效', () async {
      // v1.21.38 为了「朗读不被通知打断」，把两种模式都改成
      // `androidWillPauseWhenDucked: false`。真机反馈：
      //   「被视频打断功能没生效，反而使通知栏图标错误」。
      //
      // 原因：它不是"允许被压低音量"，而是**整个停止上报 duck 事件**。
      // 提示音与视频走**同一条 duck 路径** —— 关掉之后视频也不让位了，
      // 焦点状态与实际出声不一致，通知栏随之错乱。
      // 一个布尔值区分不了这两者，所以**必须回到 true**：
      // 宁可被提示音打断，也不能不让位给视频。
      for (final bool allow in <bool>[true, false]) {
        await StorageService.instance.setAllowMediaInterrupt(allow);
        final cfg = MediaInterruptionController.instance.debugConfiguration;
        // ignore: avoid_print
        print('DEVICE_VERIFY[media-duck] allow=$allow '
            'willPauseWhenDucked=${cfg.androidWillPauseWhenDucked}');
        expect(cfg.androidWillPauseWhenDucked, isTrue,
            reason: 'allow=$allow：必须允许 duck 暂停，'
                '否则视频/其它播放器出声时我们不让位');
      }
    });

    test('来电/其它播放器抢焦点仍然会暂停（这条没有放宽）', () async {
      var paused = 0;
      var notified = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      // ⚠️ v1.21.45 改动 1：长打断结束**不再自动继续**（暂缓那条），
      // 只重推一次播放状态。所以这里断言的是"照旧暂停 + 结束时重推状态"。
      //
      // ⚠️ v1.21.51：让位是**按类型即时**发生的 —— 永久失去焦点（`unknown`）
      // 立刻暂停，不再等宽限期。来电 / 视频走的就是这一类。
      MediaInterruptionController.instance.notifyAfterInterruptionEnded =
          () async {
        notified++;
      };

      // 永久失去焦点（真机视频实测就是 unknown）
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1, reason: '★永久失去焦点 → **立刻**让位暂停（不再延迟 2 秒）');

      // 视频这类**不会有**"结束"事件（原生已 abandonAudioFocus）；
      // 但若系统仍送来一个，我们只重推状态、不接回。
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown, begin: false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(notified, 1, reason: '打断结束后要重推一次播放状态（耳机键路由）');
    });
    // ---- v1.21.51（用户拍板方案三）：**按类型分流，不再靠时长猜** ----
    //
    // 真机取证（2026-10-15 00:10）拿到了决定性的类型差异：
    //   微信通知 → `type=pause`（1.1 秒后有 begin=false）
    //   播放视频 → `type=unknown`（**永远没有** begin=false）
    // 与 audio_session 源码逐条对上（core.dart:254-283）：
    //   lossTransient / lossTransientCanDuck → pause / duck（瞬时，会结束）
    //   loss（永久失去焦点）                 → unknown（不会再有结束事件）
    // 且 unknown 在 Android 上**只有 loss 这一个来源**。
    test('★提示音（瞬时让位 pause/duck）：**全程不暂停**，朗读不中断', () async {
      for (final type in <AudioInterruptionType>[
        AudioInterruptionType.duck,
        AudioInterruptionType.pause,
      ]) {
        var paused = 0;
        var resumed = 0;
        MediaInterruptionController.instance.pauseForInterruption = () async {
          paused++;
        };
        MediaInterruptionController.instance.resumeAfterInterruption = () async {
          resumed++;
        };

        MediaInterruptionController.instance.debugInterrupt(type);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(paused, 0, reason: '$type：瞬时让位**不许暂停** —— 暂停过就得整句重读');

        // 提示音很快结束（真机微信通知 1147ms）
        MediaInterruptionController.instance
            .debugInterrupt(type, begin: false);
        await Future<void>.delayed(Duration.zero);

        // ignore: avoid_print
        print('DEVICE_VERIFY[transient-$type] paused=$paused resumed=$resumed');
        expect(paused, 0, reason: '$type：全程没暂停过，朗读是连续的');
        expect(resumed, 0, reason: '没暂停就不需要接回');

        MediaInterruptionController.instance.resetForTest();
      }
    });

    test('★视频（永久失去焦点 unknown）：**立刻**让位暂停，不自动接回', () async {
      var paused = 0;
      var resumed = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };

      // 真机视频实测：报的就是 unknown（= 永久失去焦点）
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1,
          reason: '★永久失去焦点必须**立刻**让位（v1.21.50 曾要等 2 秒，用户反馈太慢）');

      // 这类**不会有**"结束"事件（原生已 abandonAudioFocus）
      // 若系统仍送来一个：按既有设计不自动接回
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(resumed, 0, reason: '视频还在放就突然冒出朗读更糟 —— 不自动接回');
      // ignore: avoid_print
      print('DEVICE_VERIFY[permanent-unknown] paused=$paused resumed=$resumed');
    });

    test('★真机场景：先通知（pause）再视频（unknown）→ 只让位一次，不重复', () async {
      // 真机日志（2026-10-15 00:10）里就是这么串起来的：
      // 通知先来（pause，不暂停）→ 紧接着视频（unknown，让位暂停）。
      var paused = 0;
      var resumed = 0;
      var notified = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance.notifyAfterInterruptionEnded =
          () async {
        notified++;
      };

      // 1) 通知：瞬时让位，**不暂停**
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 0, reason: '通知不打断朗读');
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(paused, 0, reason: '通知结束，全程没暂停');
      expect(notified, 0, reason: '通知不需要重推状态');

      // 2) 视频：永久失去焦点 → 立刻让位
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1, reason: '★视频必须立刻让位');

      // 3) 重复的"永久失去"不该重复暂停
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1, reason: '已经让位过了，不重复调暂停');

      // ignore: avoid_print
      print('DEVICE_VERIFY[notify-then-video] paused=$paused resumed=$resumed '
          'notified=$notified');
      expect(resumed, 0, reason: '视频这类不自动接回');
    });

    // ================================ 微信通知：报成 pause 但只响一下（v1.21.50）
    //
    // ★真机取证（2026-10-14 23:05，日志原文）：
    // ```
    // 音频打断[收到] type=pause begin=true
    // 音频打断[收到] type=pause begin=false   ← 仅 1147ms 后
    // ```
    // 微信通知**报的是 `pause` 而不是 `duck`**，类型分不出提示音与视频。
    //
    // v1.21.49 曾按"持续多久"改成"短的就接回" —— 但用户反馈那仍然**会重读这一句**
    // （Android TTS 没有半句续读能力）。v1.21.50 按用户拍板改成：
    // **宽限期内根本不暂停**，于是朗读全程连续、没有"重读"这回事。
    test('★微信通知（报成 pause，只响 1.1 秒）→ **全程不暂停**，不重读', () async {
      var paused = 0;
      var resumed = 0;
      var notified = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance.notifyAfterInterruptionEnded =
          () async {
        notified++;
      };

      // 微信来消息：系统报 pause（不是 duck），1.1 秒后结束
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 0, reason: '★宽限期内不许暂停 —— 暂停过就得整句重读');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause, begin: false);
      await Future<void>.delayed(Duration.zero);

      // ignore: avoid_print
      print('DEVICE_VERIFY[wechat-notify] paused=$paused resumed=$resumed '
          'notified=$notified');
      expect(paused, 0,
          reason: '★★微信通知**完全不该打断朗读** —— 不暂停，也就不会重读');
      expect(resumed, 0, reason: '没暂停过就不需要接回');
      expect(notified, 0, reason: '短暂通知不重推状态');
    });

    test('永久失去焦点（unknown）：让位后不自动接回 —— 别把视频当通知', () async {
      var resumed = 0;
      var notified = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {};
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance.notifyAfterInterruptionEnded =
          () async {
        notified++;
      };

      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown, begin: false);
      await Future<void>.delayed(Duration.zero);

      expect(resumed, 0,
          reason: '视频还在放就突然冒出朗读，比"停着不动"更糟 —— 这条不能放宽');
      expect(notified, 1);
    });

    test('用户自己暂停过：打断结束后不自动继续', () async {
      var resumed = 0;
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      // 用户按了暂停
      MediaInterruptionController.instance.notifyUserPaused();
      expect(MediaInterruptionController.instance.debugUserPaused, isTrue);

      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause);
      await Future<void>.delayed(Duration.zero);
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(resumed, 0,
          reason: '用户自己按的暂停不该被系统打断逻辑重新拉起来');

      // 用户按了播放：之后又可以被自动继续
      MediaInterruptionController.instance.notifyUserResumed();
      expect(MediaInterruptionController.instance.debugUserPaused, isFalse);
    });

    // ★真机日志暴露的 bug（2026-10-15 00:25）：用户手动恢复后"已让位"标志没清
    //
    // 日志原文：
    // ```
    // 00:25:39  视频 → 让位暂停（pausedForIt=true）
    // 00:25:55  用户手动点播放恢复            ← 此处标志没被清
    // 00:26:30  通知来了 → "已经让位暂停过了 → 不重复处理"（用的还是旧标志）
    // ```
    // 那一次侥幸没出事（中间那条通知的结束事件顺手清了它）。但**如果用户恢复后
    // 紧接着再放一个视频**，就会走"已经让位过 → 不重复处理" → **视频不再让位**，
    // 也就是用户最在意的那条线失效。所以标志必须在"用户恢复"时清掉。
    test('★用户恢复后"已让位"标志必须清掉 —— 否则下一个视频不再让位', () async {
      var paused = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };

      // 1) 视频（永久失去焦点）→ 让位
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1, reason: '前提：视频让位暂停');
      expect(MediaInterruptionController.instance.debugPausedForInterruption,
          isTrue);

      // 2) 用户在应用内 / 通知栏点播放恢复
      MediaInterruptionController.instance.notifyUserResumed();
      expect(MediaInterruptionController.instance.debugPausedForInterruption,
          isFalse,
          reason: '★恢复播放后这次打断就翻篇了，标志必须清掉');

      // 3) 又来一个视频 → **必须再次让位**
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // ignore: avoid_print
      print('DEVICE_VERIFY[stale-flag] paused=$paused');
      expect(paused, 2,
          reason: '★★第二个视频必须照样让位（旧标志不清就会在这里失效）');
    });

    test('★提示音（duck）结束：不重推状态、不接回 —— 因为压根没暂停过', () async {
      // ⚠️ 这条原来叫「短打断结束：仍然自动接回 —— v1.21.39 行为回归」，
      // 断言 `resumed == 1`。v1.21.50 按用户拍板改了设计：
      // **宽限期内根本不暂停** → 没有"接回"这回事（也就没有整句重读）。
      var resumed = 0;
      var notified = 0;
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance.notifyAfterInterruptionEnded =
          () async {
        notified++;
      };

      // 系统提示音：duck 起来，然后在宽限期内结束
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck, begin: false);
      await Future<void>.delayed(Duration.zero);

      expect(resumed, 0,
          reason: '★没暂停就不需要接回；接回反而意味着"刚才停过、要重读"');
      expect(notified, 0, reason: '短暂提示音不需要重推状态');
    });

    test('导航播报 / 提示音（duck，很快结束）：同样**不暂停**', () async {
      // ⚠️ 这条的行为在 v1.21.50 **按用户拍板改过**（原来断言"要让位、再自动接回"）：
      // 用户明确要求"通知不要打断朗读"，而"暂停再接回"必然导致**整句重读**
      // （Android TTS 没有从半句续读的能力）。现在宽限期内根本不暂停。
      var paused = 0;
      var resumed = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(paused, 0, reason: '★宽限期内不许暂停');
      expect(MediaInterruptionController.instance.debugPausedForInterruption,
          isFalse);

      // 提示音结束
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(paused, 0, reason: '★全程没暂停 → 朗读连续，没有"重读这一句"');
      expect(resumed, 0, reason: '没暂停就不需要接回');
    });

    test('没被打断过时收到「结束」事件不会乱继续', () async {
      var resumed = 0;
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(resumed, 0);
    });

    // ==================================================== 打断后真的能接回来
    //
    // ★v1.21.48 真机 bug：「**TTS 有概率无响应**」，且紧跟"微信通知打断"之后。
    //
    // 上面那些用例都只数回调次数（`resumeAfterInterruption` 有没有被调），
    // **测不到"调了但什么都没发生"**。这一组用真的 [TtsManager] 把整条链接起来：
    //   假引擎挂住不回调 → 模拟微信通知 duck → 暂停 → 等自动接回 → 断言"又开始读了"。
    //
    // 根因在 `TtsManager.resume()` 的闸门：原来要求 `_speaking && _paused`，
    // 而打断时 `pause()` 会把 `_speaking` 变成 false → `resume()` 直接 return，
    // 于是**永远不动**（本句的完成回调已在暂停时被吃掉，没有别的回调会再来）。
    group('打断后真的接回来（不只是"调了回调"）', () {
      testWidgets('★通知（duck）打断 → 自动接回后必须**真的继续读下一句**',
          (tester) async {
        final engine = _HangingEngine();
        await TtsManager.instance.registerEngine(engine, makeActive: true);
        final tts = TtsManager.instance;
        // 句子长一点、超时给足：本用例要的是"有没有重新开口"，不是超时行为
        tts.speakTimeout = const Duration(seconds: 30);

        tts.loadDocument(
          StructuredDocument(
            chapters: <Chapter>[
              const Chapter(
                title: '第一章',
                paragraphs: <Paragraph>[
                  Paragraph(sentences: <Sentence>[
                    Sentence('第一句。'),
                    Sentence('第二句。'),
                    Sentence('第三句。'),
                  ]),
                ],
              ),
            ],
          ),
          title: '打断用例',
          documentId: 'interrupt',
        );
        tts.speakFrom(0, 0, 0);

        // 等它真的开始读第一句（这里必须用 pump 推进，`test()` 里的
        // `Future.delayed` 在 fake_async 下不会真的走时间）
        for (var i = 0; i < 40 && engine.spoken.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(engine.spoken, isNotEmpty, reason: '前提：第一句已经开口');

        // 真机接线方式（与 TtsAudioHandler 一致）
        MediaInterruptionController.instance.pauseForInterruption =
            () async => tts.pause();
        MediaInterruptionController.instance.resumeAfterInterruption =
            () async => tts.playFromCursor();

        // 微信通知：duck（真机上系统报的是 pause，两者现在走同一条宽限路径）
        MediaInterruptionController.instance
            .debugInterrupt(AudioInterruptionType.duck);
        await tester.pump(const Duration(milliseconds: 100));
        // ignore: avoid_print
        print('DBG 打断中：paused=${tts.paused} playing=${tts.playing} '
            'spoken=${engine.spoken} '
            'pausedForIt=${MediaInterruptionController.instance.debugPausedForInterruption}');
        expect(tts.paused, isFalse,
            reason: '★宽限期内**不许暂停** —— 一旦暂停，恢复时只能整句重读');
        expect(tts.playing, isTrue, reason: '★朗读必须一直在播（这就是"不打断"）');

        // 提示音很快结束（真机微信通知 1147ms）
        MediaInterruptionController.instance
            .debugInterrupt(AudioInterruptionType.duck, begin: false);
        await tester.pump(const Duration(milliseconds: 120));

        final spokenAfterInterrupt = List<String>.of(engine.spoken);
        // ignore: avoid_print
        print('DEVICE_VERIFY[no-interrupt] spoken=$spokenAfterInterrupt '
            'paused=${tts.paused} playing=${tts.playing}');
        expect(spokenAfterInterrupt.length, 1,
            reason: '★★通知期间**不应该重读**（spoken=$spokenAfterInterrupt）：'
                '第一句还在读、没有被停下来重发');
        expect(tts.playing, isTrue, reason: '★朗读仍在继续');

        // 收尾：把挂着的引擎放行、停掉会话，别留悬挂的 await 让收尾报假红
        await tts.stop();
        await tester.pump(const Duration(milliseconds: 50));
      });
    });
  });

  group('设置页控件', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('开关在、能改；两个耳机选项已删（v1.21.43 需求三）', (tester) async {
      await pumpSettings(tester);

      // 卡片不在首屏最上方（外观 / 排版在前面），滚到它
      await tester.scrollUntilVisible(
        find.byKey(SettingsPage.mediaInterruptKey),
        200,
        maxScrolls: 30,
      );
      expect(find.byKey(SettingsPage.mediaInterruptKey), findsOneWidget);
      expect(StorageService.instance.allowMediaInterrupt, isTrue);

      // ★v1.21.43 需求三：耳机键的「按句 / 按章」两个单选**已被删除**，
      // 固定为按句。这里断言它们**不存在** —— 若将来有人把 UI 加回来，
      // 这条会红，提醒"这是被有意删掉的产品决策，不是漏了"。
      expect(find.byKey(const ValueKey<String>('headset-key-sentence')),
          findsNothing, reason: '★按句/按章单选已删除（需求三）');
      expect(find.byKey(const ValueKey<String>('headset-key-chapter')),
          findsNothing, reason: '★按句/按章单选已删除（需求三）');

      // 关掉「允许其它媒体打断」
      await tester.tap(find.byKey(SettingsPage.mediaInterruptKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(StorageService.instance.allowMediaInterrupt, isFalse,
          reason: '开关应当写进设置');
    });
  });
}
