import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_cache.dart';
import 'package:tts_reader/services/document_service.dart';

/// 大文件解析耗时实测（默认跳过，`--dart-define=PERF=1` 时打开）。
///
/// 跑法：
/// ```
/// flutter test test/perf_parse_test.dart --dart-define=PERF=1
/// ```
/// 输出的是「首次解析」与「命中缓存」两条路径的耗时对比，
/// 也是这一层优化唯一的验收标准。
const bool kRunPerf = bool.fromEnvironment('PERF');

void main() {
  test('大 TXT 首次解析 vs 命中缓存', () async {
    if (!kRunPerf) {
      // ignore: avoid_print
      print('PERF 跳过（加 --dart-define=PERF=1 打开）');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('tts_perf');
    final file = File('${dir.path}/big.txt');

    // 造一本约 12 MB / 3000 章 的小说（接近真实网文导出的体量）
    final buffer = StringBuffer();
    for (var c = 1; c <= 3000; c++) {
      buffer.writeln('第 $c 章 章节标题');
      for (var p = 0; p < 12; p++) {
        buffer.writeln(
          '这是第 $c 章的第 $p 段正文。作者在这里写了很长的一句话，'
          '用来把文件撑到接近真实小说的体量，方便测量解析耗时！'
          '还有一句带问号的结尾吗？',
        );
      }
      buffer.writeln();
    }
    file.writeAsStringSync(buffer.toString());
    final size = file.lengthSync();

    final cacheDir = await DocumentService.cacheDirectory(basePath: dir.path);
    final document = Document(
      id: 'perf_big',
      title: '性能测试',
      path: file.path,
      type: DocumentType.txt,
      importedAt: DateTime.now(),
    );

    final swFirst = Stopwatch()..start();
    final first = await DocumentService.parse(document, cacheDir: cacheDir);
    swFirst.stop();

    final swSecond = Stopwatch()..start();
    final second = await DocumentService.parse(document, cacheDir: cacheDir);
    swSecond.stop();

    final cacheFile =
        '$cacheDir${Platform.pathSeparator}${DocumentCache.fileNameFor(document.id)}';
    final cacheSize = File(cacheFile).lengthSync();

    // ignore: avoid_print
    print(
      'PERF 文件=${(size / 1024 / 1024).toStringAsFixed(1)}MB '
      '章=${first.document.chapters.length} 句=${first.document.sentenceCount} '
      '| 首次解析=${swFirst.elapsedMilliseconds}ms '
      '| 命中缓存=${swSecond.elapsedMilliseconds}ms（fromCache=${second.fromCache}）'
      '| 缓存=${(cacheSize / 1024 / 1024).toStringAsFixed(1)}MB',
    );

    expect(first.fromCache, isFalse);
    expect(second.fromCache, isTrue);
    expect(second.document.sentenceCount, first.document.sentenceCount);
    expect(swSecond.elapsedMilliseconds, lessThan(swFirst.elapsedMilliseconds));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
