import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/c2s.dart';

/// 复制即朗读（C2S：悬浮球 / 快捷磁贴 / 开机自启）的 Dart 侧验证。
///
/// 原生实现（悬浮窗、磁贴、开机广播）在设备上验证；这里验证配置解析、
/// 通道调用与失败兜底 —— 附加能力坏掉绝不能影响主流程。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = C2sController.instance;
  late List<MethodCall> calls;
  Object? Function(MethodCall call)? respond;

  setUp(() {
    controller.resetForTest();
    calls = <MethodCall>[];
    respond = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(C2sController.channel, (call) async {
          calls.add(call);
          return respond?.call(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(C2sController.channel, null);
    controller.resetForTest();
  });

  group('配置解析', () {
    test('完整配置', () {
      final config = C2sConfig.fromMap(const <String, dynamic>{
        'enabled': true,
        'autoShow': false,
        'sizeDp': 60,
        'running': true,
        'overlayPermission': true,
        'minSizeDp': 40,
        'maxSizeDp': 72,
      });
      expect(config.enabled, isTrue);
      expect(config.autoShow, isFalse);
      expect(config.sizeDp, 60);
      expect(config.running, isTrue);
      expect(config.overlayPermission, isTrue);
      expect(config.active, isTrue);
      expect(config.needsPermission, isFalse);
    });

    test('坏数据 / 缺字段退回默认值', () {
      expect(C2sConfig.fromMap(null).enabled, isFalse);
      final config = C2sConfig.fromMap(const <String, dynamic>{
        'enabled': 'yes',
        'sizeDp': '64',
        'autoShow': null,
      });
      expect(config.enabled, isFalse, reason: '不是布尔就当没开');
      expect(config.sizeDp, 64, reason: '字符串数字也要认得');
      expect(config.autoShow, isTrue, reason: '默认是复制后弹一下');
    });

    test('开了但没权限：needsPermission 为真', () {
      const config = C2sConfig(enabled: true, overlayPermission: false);
      expect(config.needsPermission, isTrue);
      expect(config.active, isFalse);
    });
  });

  group('通道调用', () {
    test('refresh 读回配置', () async {
      respond = (call) => call.method == 'getConfig'
          ? <String, dynamic>{
              'enabled': true,
              'autoShow': true,
              'sizeDp': 48,
              'running': true,
              'overlayPermission': true,
            }
          : null;
      await controller.refresh();
      expect(calls.single.method, 'getConfig');
      expect(controller.config.sizeDp, 48);
      expect(controller.supported, isTrue);
      expect(controller.config.active, isTrue);
    });

    test('apply 把开关与大小写进原生，并读回运行状态', () async {
      respond = (call) =>
          call.method == 'apply' ? true : <String, dynamic>{'overlayPermission': true};
      final running = await controller.apply(enabled: true, sizeDp: 64);
      expect(calls.first.method, 'apply');
      expect(calls.first.arguments, <String, dynamic>{'enabled': true, 'sizeDp': 64});
      expect(running, isTrue);
      expect(controller.config.running, isTrue);
      expect(controller.config.enabled, isTrue, reason: '本地也要立刻生效，界面不必等原生');
    });

    test('原生说没启动成功时如实反映', () async {
      respond = (call) => call.method == 'apply' ? false : null;
      final running = await controller.apply(enabled: true);
      expect(running, isFalse);
      expect(controller.config.running, isFalse);
      expect(controller.config.enabled, isTrue);
    });

    test('权限查询与申请', () async {
      respond = (call) => call.method == 'hasOverlayPermission' ? true : null;
      expect(await controller.hasOverlayPermission(), isTrue);
      await controller.requestOverlayPermission();
      expect(calls.map((call) => call.method), contains('requestOverlayPermission'));
    });

    test('朗读剪贴板走原生（Android 10+ 只有前台界面读得到剪贴板）', () async {
      await controller.speakClipboard();
      expect(calls.single.method, 'speakClipboard');
    });
  });

  group('原生缺失时的兜底', () {
    test('没有原生实现时标记为不支持，且不抛异常', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(C2sController.channel, null);
      await controller.refresh();
      expect(controller.supported, isFalse);
      expect(controller.config.enabled, isFalse);
      expect(await controller.apply(enabled: true), isFalse);
      expect(await controller.hasOverlayPermission(), isFalse);
      await controller.requestOverlayPermission();
      await controller.speakClipboard();
    });

    test('原生抛异常时也只是返回失败', () async {
      respond = (call) => throw PlatformException(code: 'boom');
      expect(await controller.apply(enabled: true), isFalse);
      expect(await controller.hasOverlayPermission(), isFalse);
      await controller.refresh();
      expect(controller.supported, isTrue, reason: '异常不等于平台不支持');
    });
  });

  group('启动引导', () {
    test('开关开着但悬浮球没跑：启动时补拉一次', () async {
      respond = (call) => switch (call.method) {
        'getConfig' => <String, dynamic>{
          'enabled': true,
          'autoShow': true,
          'sizeDp': 52,
          'running': false,
          'overlayPermission': true,
        },
        'apply' => true,
        _ => null,
      };
      await controller.bootstrap();
      expect(
        calls.map((call) => call.method),
        <String>['getConfig', 'apply'],
        reason: '开机自启被系统拦掉后，打开应用要能把悬浮球拉回来',
      );
      expect(controller.config.running, isTrue);
    });

    test('开关关着时什么都不做', () async {
      respond = (call) => call.method == 'getConfig'
          ? <String, dynamic>{'enabled': false, 'running': false, 'overlayPermission': true}
          : null;
      await controller.bootstrap();
      expect(calls.map((call) => call.method), <String>['getConfig']);
    });

    test('没有权限时不盲目启动（否则会弹授权页打断用户）', () async {
      respond = (call) => call.method == 'getConfig'
          ? <String, dynamic>{'enabled': true, 'running': false, 'overlayPermission': false}
          : null;
      await controller.bootstrap();
      expect(calls.map((call) => call.method), <String>['getConfig']);
    });
  });
}
