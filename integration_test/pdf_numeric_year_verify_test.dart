import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_layer.dart';

/// **目标文档真机自测**（v1.21.29）：第 8 页的「1943 / 1960」必须随整句读出。
///
/// 跑法（先在设备上放文档）：
/// ```
/// adb push <目标文档> /data/local/tmp/target.pdf
/// flutter --no-version-check test integration_test/pdf_numeric_year_verify_test.dart -d <device>
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('目标文档第 8 页：数字年份随整句读出，不跳读、不回头、不混句', (tester) async {
    final File src = File('/data/local/tmp/target.pdf');
    expect(src.existsSync(), isTrue,
        reason: '需要 adb push 目标文档到 /data/local/tmp/target.pdf');

    final PdfDocument doc = await PdfDocument.openFile(src.path);
    addTearDown(() => doc.dispose());
    // ignore: avoid_print
    print('DEVICE_PROBE[文档] 页数=${doc.pages.length}');
    final PdfPage page = doc.pages[7]; // 第 8 页（0 起）
    final layer = await loadTextLayer(page);
    expect(layer, isNotNull, reason: '第 8 页应能抽出文本层');

    // 打印所有句子（供人工核对分句是否被数字切开）
    for (var i = 0; i < layer!.sentences.length; i++) {
      // ignore: avoid_print
      print('DEVICE_PROBE[第8页 S$i] 「${layer.sentences[i].text}」');
    }

    // ★ 关键断言：数字必须与整句一起出现，不能单独成句
    final joined = layer.sentences.map((s) => s.text).join('|');
    expect(joined, contains('1943'),
        reason: '数字 1943 必须出现在某句里；若只在小段里出现、与其他句子分离，就是本次 bug');
    expect(joined, contains('1960'), reason: '数字 1960 同理');

    final withYear = layer.sentences.firstWhere((s) => s.text.contains('1943'));
    expect(withYear.text.length, greaterThan(15),
        reason: '含「1943」的那一句应当是一句完整的话，不能被截成「1943 年开始，」这一小段。'
            '实际句子：「${withYear.text}」');

    final idx1943 = layer.sentences.indexWhere((s) => s.text.contains('1943'));
    final idx1960 = layer.sentences.indexWhere((s) => s.text.contains('1960'));
    // ignore: avoid_print
    print('DEVICE_PROBE[第8页] 含 1943 的句下标=$idx1943 含 1960 的句下标=$idx1960');
    expect(idx1943, lessThanOrEqualTo(idx1960),
        reason: '含 1943 的句子不该排在含 1960 的句子之后（说明数字块被切出行外后重排）');

    // 打印字符盒几何：万一单测绿、这里红，用它调 band 系数
    for (final s in layer.sentences) {
      for (final c in s.chars) {
        // ignore: avoid_print
        print('CHAR「${c.char}」rect=${c.rect}');
      }
    }
  });
}
