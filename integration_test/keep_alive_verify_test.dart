import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/services/keep_alive.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层验证：**熄屏之后朗读继续**（后台朗读保活）。
///
/// 这个用例自己不会去关屏——关屏由外面的脚本在读到 `started` 标记后执行：
/// ```
/// adb shell input keyevent 26          # 熄屏
/// adb shell dumpsys power | findstr mWakefulness   # 应为 Asleep
/// ```
/// 所以断言放在「熄屏窗口内进度仍在推进」上：
/// 前 4 秒取一次进度，再过 20 秒再取一次，两次都应当落在熄屏期间。
///
/// 跑法：flutter test integration_test/keep_alive_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('熄屏后朗读继续推进，停止后释放唤醒锁', (tester) async {
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.stop();

    // 40 句足够撑满整个观察窗口
    tts.speakLines(List<String>.generate(40, (i) => '第 $i 句，用来验证熄屏之后朗读是否继续。'));
    // ignore: avoid_print
    print('DEVICE_VERIFY[keeplive] started');

    // 每 2 秒采样一次：熄屏由外部脚本在 started 之后约 2 秒执行，
    // 这样能看到「熄屏那一刻到底发生了什么」（是停了、报错了还是继续读）
    final samples = <String>[];
    final indices = <int>[];
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      samples.add('t=${(i + 1) * 2}s idx=${tts.plainIndex} speaking=${tts.speaking} err=${tts.error}');
      indices.add(tts.plainIndex);
    }
    for (final line in samples) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[keeplive] $line');
    }

    final heldWhileReading = KeepAliveService.instance.held;
    final speaking = tts.speaking;
    final first = indices.first;
    final last = indices.last;
    // ignore: avoid_print
    print(
      'DEVICE_VERIFY[keeplive] summary held=$heldWhileReading speaking=$speaking '
      'first=$first last=$last total=${tts.plainTotal} err=${tts.error}',
    );

    expect(heldWhileReading, isTrue, reason: '朗读期间应当持有 CPU 唤醒锁');
    expect(last, greaterThan(first), reason: '熄屏期间朗读应当继续推进');
    expect(speaking, isTrue, reason: '熄屏不该把朗读打断');
    expect(tts.error, isNull, reason: '熄屏期间不该出现朗读错误');

    await tts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // ignore: avoid_print
    print('DEVICE_VERIFY[keeplive] afterStop held=${KeepAliveService.instance.held}');
    expect(KeepAliveService.instance.held, isFalse, reason: '停止朗读后应当释放唤醒锁');
  });
}
