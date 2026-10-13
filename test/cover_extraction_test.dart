import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';

/// 封面抽取优先级（v1.21.17 第 3 件）
///
/// 需求：**EPUB 封面改用手动解 OPF（Cmbok 方案），优先于 epubx**。
/// 手动方案直接读 zip 里的 OPF（EPUB3 `properties="cover-image"` →
/// EPUB2 `<meta name="cover">` → 文件名兜底），不依赖 epubx 的封面解码。
///
/// 这条用例不看"有没有抽到图"（那需要一本真 EPUB），只看**尝试顺序** ——
/// 顺序才是本件的需求本身，而且用一个假文件就能确定性地测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('EPUB 封面：手动解 OPF 必须排第一（epubx 退居兜底）', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('cover_order');
    addTearDown(() => tmp.delete(recursive: true));

    // 故意放一个**不是 zip** 的文件：两条路都会失败，但尝试顺序照样会被记下来
    final File fake = File('${tmp.path}/fake.epub');
    await fake.writeAsString('这不是一个真正的 epub');
    final String outPath = '${tmp.path}/cover.jpg';

    DocumentService.debugCoverAttempts.clear();
    final Document doc = Document(
      id: 'cover-order',
      title: '封面顺序用例',
      path: fake.path,
      type: DocumentType.epub,
      importedAt: DateTime.now(),
    );
    await DocumentService.extractCover(doc, outPath);

    // ignore: avoid_print
    print('PROBE[封面顺序] ${DocumentService.debugCoverAttempts}');
    expect(DocumentService.debugCoverAttempts, isNotEmpty,
        reason: '至少要走一条封面路径');
    expect(DocumentService.debugCoverAttempts.first, 'opf',
        reason: '手动解 OPF 必须优先（Cmbok 方案）；'
            '实际顺序=${DocumentService.debugCoverAttempts}');
  });

  test('EPUB 封面：两条路都失败时仍然给出默认样式封面（不留空）', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('cover_fallback');
    addTearDown(() => tmp.delete(recursive: true));
    final File fake = File('${tmp.path}/fake2.epub');
    await fake.writeAsString('也不是 epub');
    final String outPath = '${tmp.path}/cover2.jpg';
    final Document doc = Document(
      id: 'cover-fallback',
      title: 'Fallback Cover',
      path: fake.path,
      type: DocumentType.epub,
      importedAt: DateTime.now(),
    );
    final String? result = await DocumentService.extractCover(doc, outPath);
    expect(result, isNotNull, reason: '抽不到图源要落到默认样式封面');
    expect(await File(result!).exists(), isTrue);
    expect(await File(result).length(), greaterThan(0));
  });
}
