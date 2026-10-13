import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_engine.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 本地 TTS 引擎选择验证。
///
/// 设备上装了多个语音引擎（Google 语音服务、三星 TTS、讯飞…）时要能切换；
/// 测试环境没有原生实现，所以这里用一个「既是系统引擎、又能枚举本地引擎」的假引擎，
/// 验证调度中心这一侧的行为：枚举、切换、持久化、清空音色。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tts = TtsManager.instance;
  late _FakeLocalHost engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    tts.resetLocalEngineForTest();
    engine = _FakeLocalHost();
    // 假引擎用系统引擎的 id 注册，正好顶替掉真的系统引擎
    await tts.registerEngine(engine, makeActive: true);
  });

  tearDown(() {
    tts.resetLocalEngineForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  group('引擎名映射', () {
    test('常见引擎包名认得出中文名', () {
      expect(LocalTtsEngine.labelOf('com.google.android.tts'), 'Google 语音服务');
      expect(LocalTtsEngine.labelOf('com.samsung.android.tts'), '三星 TTS');
      expect(LocalTtsEngine.labelOf('com.iflytek.speechcloud'), '讯飞语音');
      expect(LocalTtsEngine.labelOf('com.huawei.tts'), '华为语音');
    });

    test('认不出来就用包名末段，空壳也安全', () {
      expect(LocalTtsEngine.labelOf('com.example.my.ttsengine'), 'ttsengine');
      expect(LocalTtsEngine.labelOf('single'), 'single');
      expect(LocalTtsEngine.labelOf(''), '未知引擎');
    });
  });

  group('枚举与切换', () {
    test('枚举出的引擎带默认 / 当前标记', () async {
      await tts.refreshLocalEngines();
      final engines = tts.localEngines;
      expect(engines.length, 3);
      expect(engines.firstWhere((e) => e.package == 'com.google.android.tts').isDefault, isTrue);
      // 还没选过：当前生效的是系统默认
      expect(engines.firstWhere((e) => e.package == 'com.google.android.tts').isCurrent, isTrue);
      expect(tts.localEngineLabel, 'Google 语音服务');
    });

    test('切换本地引擎：调用引擎、记住包名、清空音色', () async {
      await tts.refreshLocalEngines();
      // 先假装有一堆旧引擎的音色
      await tts.refreshVoices();
      expect(tts.voices, isNotEmpty);

      await tts.setLocalEngine('com.iflytek.speechcloud');

      expect(engine.used, <String>['com.iflytek.speechcloud']);
      expect(tts.localEnginePackage, 'com.iflytek.speechcloud');
      expect(tts.localEngineLabel, '讯飞语音');
      expect(tts.voices, isEmpty, reason: '换了引擎，音色列表整套都变了');
      expect(tts.activeEngineName, contains('讯飞语音'));
    });

    test('重复切同一个引擎不会打扰底层', () async {
      await tts.setLocalEngine('com.samsung.android.tts');
      await tts.setLocalEngine('com.samsung.android.tts');
      expect(engine.used, <String>['com.samsung.android.tts']);
    });

    test('切换后重新枚举，当前标记跟着走', () async {
      await tts.setLocalEngine('com.iflytek.speechcloud');
      final current = tts.localEngines.where((e) => e.isCurrent).toList();
      expect(current.length, 1);
      expect(current.single.package, 'com.iflytek.speechcloud');
    });

    test('引擎切换失败时保留原选择并记下错误', () async {
      engine.failOnUse = true;
      await tts.setLocalEngine('com.iflytek.speechcloud');
      expect(tts.localEnginePackage, isEmpty, reason: '失败就不该改配置');
      expect(tts.error, contains('切换本地引擎失败'));
    });

    test('枚举失败不影响朗读（保持上一次结果）', () async {
      await tts.refreshLocalEngines();
      expect(tts.localEngines, isNotEmpty);
      engine.failOnList = true;
      await tts.refreshLocalEngines();
      expect(tts.localEngines, isNotEmpty, reason: '枚举失败时保留旧列表，别把选择栏清空');
    });
  });

  group('持久化', () {
    test('选择写进设置，重启后按包名重建引擎', () async {
      await tts.setLocalEngine('com.samsung.android.tts');
      final settings = await StorageService.instance.loadTtsSettings();
      expect(settings['localEngine'], 'com.samsung.android.tts');
    });

    test('设置里没有这项时跟随系统默认', () async {
      final settings = await StorageService.instance.loadTtsSettings();
      expect(settings['localEngine'], anyOf(isNull, ''));
      expect(tts.localEnginePackage, isEmpty);
    });
  });
}

/// 假引擎：既是系统引擎（id = system），又能枚举 / 切换本地引擎
class _FakeLocalHost with SyntheticTtsEngine implements TtsEngine, LocalEngineHost {
  final List<String> used = <String>[];
  bool failOnUse = false;
  bool failOnList = false;
  String _package = '';

  @override
  String get id => 'system';

  @override
  String get displayName => '系统 TTS';

  @override
  bool get isAvailable => true;

  @override
  String? get enginePackage => _package.isEmpty ? null : _package;

  @override
  Future<List<LocalTtsEngine>> listLocalEngines() async {
    if (failOnList) throw StateError('枚举失败');
    // 与真实现一致：没选过时「当前」就是系统默认引擎
    final current = _package.isEmpty ? 'com.google.android.tts' : _package;
    return <LocalTtsEngine>[
      LocalTtsEngine(
        package: 'com.google.android.tts',
        label: 'Google 语音服务',
        isDefault: true,
        isCurrent: current == 'com.google.android.tts',
      ),
      LocalTtsEngine(
        package: 'com.samsung.android.tts',
        label: '三星 TTS',
        isCurrent: current == 'com.samsung.android.tts',
      ),
      LocalTtsEngine(
        package: 'com.iflytek.speechcloud',
        label: '讯飞语音',
        isCurrent: current == 'com.iflytek.speechcloud',
      ),
    ];
  }

  @override
  Future<void> useLocalEngine(String package) async {
    if (failOnUse) throw StateError('切换失败');
    used.add(package);
    _package = package;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[
    TtsVoice(id: 'v1', name: '音色一', locale: 'zh-CN'),
  ];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  void setCompletionHandler(void Function()? handler) {
    // 调度中心会注册完成回调；这里只需接受它（本用例不验证朗读推进）
    handler;
  }

  @override
  Future<void> dispose() async {}
}
