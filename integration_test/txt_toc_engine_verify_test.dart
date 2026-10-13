import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// 设备层验证：**TXT 目录解析** 与 **本地 TTS 引擎枚举 / 切换**。
///
/// 单元测试用的是构造出来的文本与假引擎；这里在真机上跑一遍：
/// - 真文件 → isolate 解析 → 章节结构与目录页数；
/// - 真 `flutter_tts.getEngines()` → 设备上到底有几个本地语音引擎。
///
/// 跑法：flutter test integration_test/txt_toc_engine_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TXT：真文件解析出章节，目录页数自洽', (tester) async {
    final dir = await Directory.systemTemp.createTemp('tts_txt_verify');
    final file = File('${dir.path}/novel.txt');
    final buffer = StringBuffer()
      ..writeln('《验收小说》')
      ..writeln('作者：某人')
      ..writeln();
    for (var i = 1; i <= 6; i++) {
      buffer.writeln('第 $i 章 第$i章标题');
      for (var p = 0; p < 5; p++) {
        buffer.writeln('这是第 $i 章的第 ${p + 1} 段内容，用来验证目录解析。');
      }
      buffer.writeln();
    }
    file.writeAsStringSync(buffer.toString());

    await StorageService.instance.init();
    final document = Document(
      id: 'txt_toc',
      title: 'novel',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime.now(),
    );

    final task = DocumentService.parseAsync(document);
    final result = await task.result;

    // ignore: avoid_print
    print(
      'DEVICE_VERIFY[txt-toc] chapters=${result.document.chapters.length} '
      'paragraphs=${result.document.paragraphCount} sentences=${result.document.sentenceCount}',
    );
    for (final chapter in result.document.chapters) {
      // ignore: avoid_print
      print('DEVICE_VERIFY[txt-toc] 章「${chapter.title}」段=${chapter.paragraphs.length}');
    }

    expect(result.document.chapters.length, 7, reason: '开篇 + 6 章');
    expect(result.document.chapters.first.title, '开篇');
    expect(result.document.chapters[1].title, '第 1 章 第1章标题');
    expect(result.document.chapters.last.title, '第 6 章 第6章标题');
    expect(result.document.chapters[1].paragraphs.length, 5);

    // 目录页数：每章 5 段、每页 2 段 → 每章 3 页
    const perPage = 2;
    final pages = <int>[];
    for (var c = 0; c < result.document.chapters.length; c++) {
      pages.add(result.document.pageCountOf(c, perPage));
    }
    final total = result.document.totalPages(perPage);
    // ignore: avoid_print
    print('DEVICE_VERIFY[txt-toc] pages=$pages total=$total');
    expect(total, pages.fold<int>(0, (sum, value) => sum + value));
    expect(pages[1], 3, reason: '5 段 / 每页 2 段 = 3 页');
    expect(result.document.pageStartOf(1, 2, perPage), 4, reason: '第 3 页从第 5 段开始');
    expect(result.document.pageStartOf(1, 3, perPage), isNull, reason: '越界页返回 null');

    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 忽略
    }
  });

  testWidgets('本地 TTS：枚举设备引擎并切换', (tester) async {
    await StorageService.instance.init();
    final tts = TtsManager.instance;
    await tts.init();
    await tts.refreshLocalEngines();

    final engines = tts.localEngines;
    // ignore: avoid_print
    print('DEVICE_VERIFY[local-tts] 共 ${engines.length} 个：'
        '${engines.map((e) => '${e.label}<${e.package}>${e.isDefault ? " 默认" : ""}${e.isCurrent ? " 当前" : ""}').join(" | ")}');

    expect(engines, isNotEmpty, reason: '真机上至少有一个本地 TTS 引擎');
    for (final engine in engines) {
      expect(engine.package, isNotEmpty);
      expect(engine.label, isNotEmpty);
    }
    // 恰好一个「当前」
    expect(engines.where((e) => e.isCurrent).length, lessThanOrEqualTo(1));

    final target = engines.first;
    await tts.setLocalEngine(target.package);
    // ignore: avoid_print
    print('DEVICE_VERIFY[local-tts] 已切换到 ${tts.localEngineLabel}（${tts.localEnginePackage}）'
        '，音色 ${tts.voices.length} 个，错误=${tts.error}');
    expect(tts.localEnginePackage, target.package);
    expect(tts.activeEngineName, contains(target.label));

    // 切完之后仍然能读：真读一小段，确认没有把引擎弄坏
    tts.speakLines(<String>['切换引擎之后的测试句子。', '第二句。']);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) && tts.speaking) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[local-tts] 读完后 speaking=${tts.speaking} err=${tts.error}');
    expect(tts.error, isNull, reason: '换引擎后不该留下朗读错误');

    // 换回系统默认（空包名 = 跟随系统）
    await tts.setLocalEngine('');
    // ignore: avoid_print
    print('DEVICE_VERIFY[local-tts] 复位后 package=${tts.localEnginePackage} label=${tts.localEngineLabel}');
  });
}
