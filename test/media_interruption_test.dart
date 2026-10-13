import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/media_interruption.dart';
import 'package:tts_reader/tts/tts_manager.dart';

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
      var resumed = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };

      MediaInterruptionController.instance.debugInterrupt(
        AudioInterruptionType.pause,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(paused, 1, reason: '系统要暂停（来电）时必须暂停');

      MediaInterruptionController.instance.debugInterrupt(
        AudioInterruptionType.pause,
        begin: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(resumed, 1, reason: '打断结束后要自动继续');
    });
    // ---- v1.21.39：提示音（duck）与视频（pause）必须区分对待 ----
    test('提示音（duck）：先让位，对方马上走了就自动接回', () async {
      var paused = 0;
      var resumed = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };

      // 系统提示音 = duck（瞬时）
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck);
      await Future<void>.delayed(Duration.zero);
      expect(paused, 1, reason: '要让位（否则视频那条路也没法生效）');
      expect(resumed, 0, reason: '不能立刻接回 —— 提示音还在响');

      // 等过"短打断"窗口：对方已经结束 → 自动接着读（用户感觉没被打断）
      await Future<void>.delayed(
          MediaInterruptionController.shortDuckResumeDelay +
              const Duration(milliseconds: 150));
      expect(resumed, 1, reason: '提示音结束后应当自动接回朗读');
      // ignore: avoid_print
      print('DEVICE_VERIFY[media-duck] 提示音：paused=$paused resumed=$resumed');
    });

    test('视频（duck 后紧接 pause）：不自动接回，保持让位', () async {
      var paused = 0;
      var resumed = 0;
      MediaInterruptionController.instance.pauseForInterruption = () async {
        paused++;
      };
      MediaInterruptionController.instance.resumeAfterInterruption = () async {
        resumed++;
      };

      // 提示音先响一下（duck），紧接着视频持续出声（pause）
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.duck);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause);
      await Future<void>.delayed(Duration.zero);
      expect(paused, greaterThanOrEqualTo(2), reason: '两种打断都要暂停');

      // 等过短打断窗口：因为对方还在出声，**不能**接回
      await Future<void>.delayed(
          MediaInterruptionController.shortDuckResumeDelay +
              const Duration(milliseconds: 150));
      expect(resumed, 0, reason: '视频还在放，不能自动接回（否则就是"打断没生效"）');
      // ignore: avoid_print
      print('DEVICE_VERIFY[media-duck] 视频：paused=$paused resumed=$resumed');
    });

    test('系统要求暂停：先暂停；结束后自动继续', () async {
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
      await Future<void>.delayed(Duration.zero);
      expect(paused, 1, reason: '打断开始应当暂停朗读');

      // 对方结束
      MediaInterruptionController.instance
          .debugInterrupt(AudioInterruptionType.pause, begin: false);
      await Future<void>.delayed(Duration.zero);
      expect(resumed, 1, reason: '打断结束应当自动继续');
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

    test('duck（导航播报 / 提示音）也要让位 —— 但会自己接回', () async {
      // ⚠️ v1.21.39 改了判据：原来这条写的是"duck 不暂停"。
      // 但真机证明"不暂停"会把**视频**那条路一起废掉（两者同为 duck 路径），
      // 表现为「被视频打断功能没生效」。现在改成：**照样让位，短打断自动接回**，
      // 用"对方持续多久"区分提示音与视频（详见 controller 里 _onInterruption 的表格）。
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
      await Future<void>.delayed(Duration.zero);
      expect(paused, 1, reason: '要让位（否则视频那条路也失效）');
      expect(MediaInterruptionController.instance.debugShortDuck, isTrue);

      await Future<void>.delayed(
          MediaInterruptionController.shortDuckResumeDelay +
              const Duration(milliseconds: 150));
      expect(resumed, 1, reason: '提示音是瞬时的 → 自动接回，用户感觉没被打断');
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
