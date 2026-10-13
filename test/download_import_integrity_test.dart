import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:tts_reader/services/download_watcher.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **下载导入的完整性校验**（v1.21.43 重写版 · 块2）
///
/// ## 治什么（真机事故：半截文件被当成品导入）
///
/// 用户日志（2026-10-11 19:42）：一次下载**只到 6% 就 failed**，
/// 浏览器页正确放弃了；但**后台扫描**把那份半截文件"找到"、收纳进子文件夹、
/// 还写进了文档库 —— 用户得到的是一本打不开的书
/// （点开即 `FPDF_GetLastError=3`）。
///
/// **半截文件比"没导入"糟糕得多**：库里多一条打不开的记录，还得手动删。
///
/// ## 两道判据（缺一不可）
///
/// 1. **文件头魔数**：`.pdf` 必须以 `%PDF` 开头、`.epub` 必须以 `PK` 开头；
/// 2. **真解析一次**：⚠️ **魔数拦不住半截 PDF** —— 被截断的 PDF 开头
///    仍然是 `%PDF`（实测：造一个 199 字节的"真头残片"，魔数校验放行）。
///    唯一可靠的判据是"它到底能不能被解析"。
///
/// ⚠️ 本文件是 v1.21.42 丢失版本的**重写**，不是"恢复"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage = StorageService.instance;
    storage.resetForTest();
    await storage.init();
    tmp = Directory.systemTemp.createTempSync('dl_integrity');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响判定
    }
  });

  File write(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(bytes);
    return f;
  }

  /// 造一份**真能解析**的最小 PDF（Syncfusion 生成）
  List<int> realPdfBytes() {
    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString(
          'Real page one. Second sentence here.',
          PdfStandardFont(PdfFontFamily.helvetica, 12),
        );
    final bytes = pdf.saveSync();
    pdf.dispose();
    return bytes;
  }

  group('文件头魔数', () {
    test('describeFileHead：真 PDF 识别为 PDF', () async {
      final f = write('good.pdf', realPdfBytes());
      final head = await describeFileHead(f.path);
      // ignore: avoid_print
      print('DEVICE_VERIFY[hdr] 真PDF 头=$head');
      expect(head.startsWith('PDF'), isTrue);
    });

    test('describeFileHead：PK 开头识别为 ZIP（epub 等）', () async {
      final f = write('x.epub', <int>[0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);
      final head = await describeFileHead(f.path);
      // ignore: avoid_print
      print('DEVICE_VERIFY[hdr] PK 头=$head');
      expect(head.startsWith('ZIP'), isTrue);
    });

    test('describeFileHead：不存在的文件如实回报（不抛）', () async {
      final head = await describeFileHead('${tmp.path}/不存在.pdf');
      expect(head, contains('不存在'));
    });
  });

  group('真解析校验（魔数拦不住截断，这条才是关键）', () {
    test('★真机事故复现：半截 PDF（有 %PDF 头、内容截断）必须被拦住', () async {
      // 造「真 PDF 的前 199 字节」：有 %PDF 头，但没有 xref / %%EOF
      final whole = <int>[
        0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, // %PDF-1.7\n
        ...List<int>.filled(190, 0x20),
      ];
      final f = write('半截.pdf', whole);

      // 前置：魔数校验**会放行**它（这正是为什么还需要解析校验）
      final head = await describeFileHead(f.path);
      // ignore: avoid_print
      print('DEVICE_VERIFY[trunc] 头=$head 大小=${whole.length}B');
      expect(head.startsWith('PDF'), isTrue,
          reason: '前置：魔数确实放行截断文件');

      final doc = await importDownloadedFile(f.path);
      // ignore: avoid_print
      print('DEVICE_VERIFY[trunc] 导入结果=${doc == null ? "已拒绝" : "被导入(漏网)"}');
      expect(doc, isNull,
          reason: '★半截 PDF 解析必然失败 → 必须拒绝导入，'
              '否则库里会出现一本打不开的书（真机 19:42 那次事故）');
    });

    test('扩展名 .pdf 但内容不是 PDF → 拒绝', () async {
      final f = write('假的.pdf', '这不是 PDF，只是文本'.codeUnits);
      expect(await importDownloadedFile(f.path), isNull);
    });

    test('扩展名 .epub 但内容不是 ZIP → 拒绝', () async {
      final f = write('假的.epub', '这不是 epub'.codeUnits);
      expect(await importDownloadedFile(f.path), isNull);
    });

    test('空文件 → 拒绝', () async {
      final f = write('空.pdf', <int>[]);
      expect(await importDownloadedFile(f.path), isNull);
    });

    test('真的能解析的 PDF → 正常导入（不能把好的也拦掉）', () async {
      final f = write('正常.pdf', realPdfBytes());
      final doc = await importDownloadedFile(f.path);
      // ignore: avoid_print
      print('DEVICE_VERIFY[ok] 真PDF 导入=${doc == null ? "被拒(★误杀)" : "成功"}');
      expect(doc, isNotNull,
          reason: '★判据不能误杀：真 PDF 必须正常导入');
      expect(doc!.title, contains('正常'));
    });
  });
}
