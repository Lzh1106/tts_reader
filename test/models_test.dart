import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/models/structured_document.dart';
import 'package:tts_reader/services/document_service.dart';

void main() {
  group('Document', () {
    test('toJson / fromJson 往返一致', () {
      final document = Document(
        id: '1',
        title: '示例',
        path: r'C:\books\demo.pdf',
        type: DocumentType.pdf,
        progress: 0.42,
        importedAt: DateTime.parse('2024-05-01T10:00:00.000'),
      );
      final restored = Document.fromJson(document.toJson());
      expect(restored.id, '1');
      expect(restored.title, '示例');
      expect(restored.type, DocumentType.pdf);
      expect(restored.progress, 0.42);
      expect(restored.importedAt, document.importedAt);
    });

    test('扩展名解析', () {
      expect(DocumentType.fromExtension('/a/b/c.epub'), DocumentType.epub);
      expect(DocumentType.fromExtension('PDF'), DocumentType.pdf);
      expect(DocumentType.fromExtension('note.md'), DocumentType.txt);
    });
  });

  group('DocumentService 文本处理', () {
    test('titleFromPath 去扩展名', () {
      expect(DocumentService.titleFromPath(r'C:\books\三体.pdf'), '三体');
      expect(DocumentService.titleFromPath('/tmp/no-ext'), 'no-ext');
    });

    test('HTML 转纯文本并保留段落', () {
      final text = DocumentService.htmlToPlainText(
        '<html><head><style>p{}</style></head><body><h1>标题</h1><p>第一句。第二句！</p>'
        '<p>下一段<br/>换行</p><script>var a=1;</script></body></html>',
      );
      expect(text.contains('标题'), isTrue);
      expect(text.contains('第一句。第二句！'), isTrue);
      expect(text.contains('var a'), isFalse);
      expect(text.contains('\n\n'), isTrue);
    });

    test('解析纯文本结构（段落 / 分句 / 进度）', () {
      // 直接构造结构，避免依赖真实文件
      final document = StructuredDocument(
        chapters: const <Chapter>[
          Chapter(
            title: '全文',
            paragraphs: <Paragraph>[
              Paragraph(sentences: <Sentence>[Sentence('第一句。'), Sentence('第二句！')]),
              Paragraph(sentences: <Sentence>[Sentence('第三句？')]),
            ],
          ),
        ],
      );
      expect(document.sentenceCount, 3);
      expect(document.paragraphCount, 2);
      expect(document.progressOf((0, 0, 0)), 0);
      expect(document.progressOf((0, 1, 0)), closeTo(2 / 3, 0.0001));
      expect(document.chapters.first.text, '第一句。第二句！\n第三句？');
    });
  });
}
