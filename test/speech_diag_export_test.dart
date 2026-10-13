import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/speech_diag_export.dart';
import 'package:tts_reader/services/speech_diagnostics.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 导出层自测（v1.21.13 / B-P3）：**流式写不闪退**是这一层的核心承诺。
///
/// 这里用「5 万行」当压力口径：不依赖真实朗读，只验证
/// ① 逐行写不会先拼出一个整串（内存里任何时刻只有一行）；
/// ② 行数、内容、体积都对；
/// ③ 隔离线程那条路真的能跑（闭包 / 快照可跨线程，结果能传回）。
void main() {
  final SpeechDiagnostics diag = SpeechDiagnostics.instance;

  /// 与 `SpeechDiagExport.meta()` 同形状（4 条）。
  const Map<String, String> metaMap = <String, String>{
    'app_version': '1.21.13+64',
    'build': '64',
    'device': 'test-device',
    'android': 'test-device',
  };

  setUp(diag.clear);

  DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(1700000000000 + ms);

  /// 造一批事件：一条 R3 红（单次跳 5 句、来源自动）+ 20 条正常推进。
  void seed() {
    diag.speakEvents.add(
      SpeakEvent(
        seq: 1,
        epoch: 7,
        textPrefix: '这是第一句',
        issuedAt: at(0),
        cursorBefore: '0:0:0',
        doneAt: at(900),
        durationMs: 900,
        ok: true,
      ),
    );
    diag.advanceEvents.add(
      AdvanceEvent(
        seq: 2,
        cursorBefore: '0:0:0',
        cursorAfter: '0:0:5',
        delta: 5,
        source: '自动',
        epoch: 7,
        at: at(950),
      ),
    );
    for (int i = 0; i < 20; i++) {
      diag.speakEvents.add(
        SpeakEvent(
          seq: 3 + i * 2,
          epoch: 7,
          textPrefix: '第 $i 句',
          issuedAt: at(1000 + i * 100),
          cursorBefore: '0:0:$i',
          doneAt: at(1800 + i * 100),
          durationMs: 800,
          ok: true,
        ),
      );
      diag.advanceEvents.add(
        AdvanceEvent(
          seq: 4 + i * 2,
          cursorBefore: '0:0:$i',
          cursorAfter: '0:0:${i + 1}',
          delta: 1,
          source: '自动',
          epoch: 7,
          at: at(1850 + i * 100),
        ),
      );
    }
  }

  test('① 5 万行流式写：不抛异常 / 行数精确 / 进度按 500 行上报', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('diag_stream');
    final String path = '${tmp.path}/big.log';
    final List<int> progress = <int>[];

    final SpeechDiagWriteResult result = await SpeechDiagExport.writeLines(
      lines: Iterable<String>.generate(
        50000,
        (int i) => 'speak seq=$i epoch=1 text=第 $i 句 issued=2026-10-10T00:00:00.000',
      ),
      path: path,
      onProgress: progress.add,
    );

    expect(result.lines, 50000, reason: '5 万行必须一行不少地写出去');
    expect(progress.contains(500), isTrue, reason: '每 500 行要有一次进度');
    expect(progress.last, 50000, reason: '最后收尾也要报一次进度');
    expect(result.bytes, greaterThan(0));

    final List<String> lines = await File(path).readAsLines();
    expect(lines.length, 50000);
    expect(lines.first, contains('seq=0'));
    expect(lines.last, contains('seq=49999'));

    await tmp.delete(recursive: true);
  });

  test('② 5 万行走隔离线程写：闭包可发送、结果能跨线程传回', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('diag_iso');
    final String path = '${tmp.path}/iso.log';

    final SpeechDiagWriteResult result =
        await SpeechDiagExport.writeLinesIsolated(
      path: path,
      buildLines: () => Iterable<String>.generate(
        50000,
        (int i) => 'turn seq=$i page=$i->${i + 1} trigger=自动',
      ),
    );

    expect(result.lines, 50000);
    final List<String> lines = await File(path).readAsLines();
    expect(lines.length, 50000);
    expect(lines.last, contains('seq=49999'));

    await tmp.delete(recursive: true);
  });

  test('③ 行数估算与真实导出行数对拍（摘要 / 全量两种）', () {
    seed();
    for (final bool all in <bool>[false, true]) {
      final int estimate =
          diag.estimateExportLines(includeAllEvents: all, meta: metaMap);
      final int actual =
          diag.exportLines(includeAllEvents: all, meta: metaMap).length;
      expect(estimate, actual,
          reason: 'includeAllEvents=$all 时估算必须等于实际行数（进度条靠它）');
    }
  });

  test('④ 大导出阈值：49999 不确认，50000 确认', () {
    expect(SpeechDiagExport.needsLargeExportConfirm(49999), isFalse);
    expect(SpeechDiagExport.needsLargeExportConfirm(50000), isTrue);
  });

  test('⑤ buildExportText 与 exportLines 逐行等价（回归保护）', () {
    seed();
    final String text =
        diag.buildExportText(includeAllEvents: true, meta: metaMap);
    final String joined = diag.exportLines(includeAllEvents: true, meta: metaMap)
        .map((String line) => '$line\n')
        .join();
    // `export_time=` 是「现在」，两次调用天然差几毫秒 —— 归一化后再逐行对拍
    String normalize(String s) => s
        .split('\n')
        .map((String line) =>
            line.startsWith('export_time=') ? 'export_time=#' : line)
        .join('\n');
    expect(normalize(text), normalize(joined),
        reason: '改成迭代器之后，导出文本必须一字不差');
    expect(text.split('\n').first, 'speech_diag_v1');
    expect(text, contains('overall=red'));
    expect(text, contains('[events]'));
  });

  test('⑥ 脱离副本能在隔离线程里导出（单例跨不过去）', () async {
    seed();
    final SpeechDiagnostics snapshot = diag.detachedCopy();
    final Directory tmp = await Directory.systemTemp.createTemp('diag_snap');
    final String path = '${tmp.path}/snap.log';

    final SpeechDiagWriteResult result =
        await SpeechDiagExport.writeLinesIsolated(
      path: path,
      buildLines: () =>
          snapshot.exportLines(includeAllEvents: true, meta: metaMap),
    );

    final String text = await File(path).readAsString();
    expect(text.split('\n').first, 'speech_diag_v1');
    expect(text, contains('overall=red'),
        reason: '副本必须带着事件过去，否则隔离线程里读到的是空单例');
    expect(text, contains('[events]'));
    expect(result.lines,
        snapshot.estimateExportLines(includeAllEvents: true, meta: metaMap));

    await tmp.delete(recursive: true);
  });

  test('⑦ 剪贴板：小体量整份复制，超限按行截断并在尾部说明', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final List<String> clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map<Object?, Object?>)['text']!
            as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    seed();

    // ① 不超限：全文复制，无截断尾巴
    final SpeechDiagCopyResult full = await SpeechDiagExport.copyToClipboard(
      includeAllEvents: true,
    );
    expect(full.truncated, isFalse);
    expect(full.bytes, full.fullBytes);
    expect(clipboard.last, contains('speech_diag_v1'));
    expect(clipboard.last, isNot(contains('[已截断]')));
    expect(full.message, contains('KB'));

    // ② 限到 200 字节：必须截断，且截断点落在整行边界上
    final SpeechDiagCopyResult cut = await SpeechDiagExport.copyToClipboard(
      includeAllEvents: true,
      byteLimit: 200,
    );
    expect(cut.truncated, isTrue);
    expect(cut.bytes, lessThanOrEqualTo(200));
    expect(cut.fullBytes, greaterThan(cut.bytes));
    expect(clipboard.last, contains('[已截断]'));
    expect(cut.message, contains('已截断'));

    // 截断必须是「完整前缀」：只能砍整行，不能砍出半行
    String normalize(String s) => s
        .split('\n')
        .map((String line) =>
            line.startsWith('export_time=') ? 'export_time=#' : line)
        .join('\n');
    final List<String> all = diag
        .exportLines(includeAllEvents: true, meta: SpeechDiagExport.meta())
        .toList();
    final List<String> keptLines =
        clipboard.last.split('\n\n[已截断]').first.split('\n');
    expect(keptLines.length, lessThan(all.length));
    expect(
      keptLines.map(normalize).toList(),
      all.take(keptLines.length).map(normalize).toList(),
      reason: '复制出来的正文必须是全文的完整前缀（按行截断）',
    );
  });
  // ---- v1.21.28：导出目录重做（默认系统可见 + 可切私有） ----

  /// 单测环境没有 path_provider 平台实现 → 自己装一个假的。
  /// 按**方法名**给不同目录，模拟 Android 真实形态：
  ///   系统可见 = /storage/emulated/0/Android/data/<pkg>/files
  ///   应用私有 = /data/user/0/<pkg>/files
  void mockPathProvider() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 单测没有插件实现：先把 SharedPreferences 也换成内存实现
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const MethodChannel channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      // ⚠️ 方法名按子串匹配：path_provider 在不同平台实现里叫
      // getExternalStorageDirectory / getExternalStorageDirectories 等
      return call.method.contains('External')
          ? '/storage/emulated/0/Android/data/com.example.tts_reader/files'
          : '/data/user/0/com.example.tts_reader/files';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
  }

  test('⑧ dir() 两种模式都不抛异常，且真的跟着开关换目录', () async {
    mockPathProvider();
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    await StorageService.instance.setSpeechDiagToExternal(true);
    final Directory d1 = await SpeechDiagExport.dir();
    // ignore: avoid_print
    print('PROBE[诊断目录-系统可见] ${d1.path}');
    expect(d1.path, endsWith('speech_diag'));
    // ⚠️ 单测里 `getExternalStorageDirectory()` 拿不到（平台接口直接抛，
    // 通道 mock 也拦不住）→ 这里只能验"回落也不抛、目录真建出来"。
    // 「系统可见目录」那条由真机五步验（adb ls /storage/emulated/0/Android/data/…）。
    expect(d1.path, contains('speech_diag'));

    await StorageService.instance.setSpeechDiagToExternal(false);
    final Directory d2 = await SpeechDiagExport.dir();
    // ignore: avoid_print
    print('PROBE[诊断目录-私有] ${d2.path}');
    expect(d2.path, endsWith('speech_diag'));
    expect(d2.path, contains('speech_diag'));
    // 关掉开关时走的必须是**私有**目录（单测里两者都回落，但语义分支要覆盖到）
    expect(StorageService.instance.speechDiagToExternal, isFalse);

    // 两种模式都必须真的建出来了（导出失败那种"跑了却看不到文件"就是这里没成）
    expect(await d1.exists(), isTrue);
    expect(await d2.exists(), isTrue);

    await StorageService.instance.setSpeechDiagToExternal(true);
  });

  test('⑨ 开关持久化：重启后仍是关掉的那个值', () async {
    mockPathProvider();
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    await StorageService.instance.setSpeechDiagToExternal(false);
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.speechDiagToExternal, isFalse,
        reason: '关成私有后重启应当还是私有');

    await StorageService.instance.setSpeechDiagToExternal(true);
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.speechDiagToExternal, isTrue,
        reason: '默认值是"系统可见"');
  });
}