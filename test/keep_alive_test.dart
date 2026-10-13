import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/keep_alive.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 后台朗读保活（熄屏继续读）的 Dart 侧验证。
///
/// 原生侧持 `PARTIAL_WAKE_LOCK` + `WifiLock`；这里验证通道调用、
/// 「拿不到原生实现时静默降级」以及「保持屏幕常亮」这个开关的存取。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final keepAlive = KeepAliveService.instance;
  final storage = StorageService.instance;
  late List<MethodCall> calls;
  Object? Function(MethodCall call)? respond;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage.resetForTest();
    keepAlive.resetForTest();
    await storage.init();
    calls = <MethodCall>[];
    respond = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeepAliveService.channel, (call) async {
          calls.add(call);
          return respond?.call(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeepAliveService.channel, null);
    keepAlive.resetForTest();
  });

  group('唤醒锁', () {
    test('acquire 拿锁、release 放锁，状态跟着原生回复走', () async {
      respond = (call) => call.method == 'acquire' ? true : null;
      expect(await keepAlive.acquire(), isTrue);
      expect(keepAlive.held, isTrue);
      expect(calls.single.method, 'acquire');

      await keepAlive.release();
      expect(keepAlive.held, isFalse);
      expect(calls.map((call) => call.method), <String>['acquire', 'release']);
    });

    test('原生没给到锁时如实反映（不假装持有）', () async {
      respond = (call) => call.method == 'acquire' ? false : null;
      expect(await keepAlive.acquire(), isFalse);
      expect(keepAlive.held, isFalse);
    });

    test('重复 acquire 不会重复打扰原生', () async {
      respond = (call) => true;
      await keepAlive.acquire();
      await keepAlive.acquire();
      expect(calls.where((call) => call.method == 'acquire').length, 1);
    });

    test('原生抛异常时按「没拿到」处理，不冒泡', () async {
      respond = (call) => throw PlatformException(code: 'boom');
      expect(await keepAlive.acquire(), isFalse);
      expect(keepAlive.held, isFalse);
      await keepAlive.release(); // 不该抛
    });

    test('没有原生实现（桌面 / 测试环境）时静默降级', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(KeepAliveService.channel, null);
      expect(await keepAlive.acquire(), isFalse);
      expect(keepAlive.supported, isFalse);
      expect(await keepAlive.isIgnoringBatteryOptimizations(), isFalse);
      await keepAlive.requestIgnoreBatteryOptimizations();
    });
  });

  group('电池优化白名单', () {
    test('读状态：白名单里返回 true', () async {
      respond = (call) => call.method == 'status'
          ? <String, dynamic>{'ignoringBatteryOptimizations': true, 'held': false}
          : null;
      expect(await keepAlive.isIgnoringBatteryOptimizations(), isTrue);
    });

    test('申请入口存在时会被调用', () async {
      await keepAlive.requestIgnoreBatteryOptimizations();
      expect(calls.single.method, 'requestIgnoreBatteryOptimizations');
    });
  });

  group('保持屏幕常亮的开关', () {
    test('默认关（熄屏继续读更省电）', () {
      expect(storage.keepScreenOn, isFalse);
    });

    test('改完之后能持久化并在重启后读回', () async {
      await storage.setKeepScreenOn(true);
      expect(storage.keepScreenOn, isTrue);

      storage.resetForTest();
      await storage.init();
      expect(storage.keepScreenOn, isTrue);
    });
  });
}
