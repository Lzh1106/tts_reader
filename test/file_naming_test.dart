import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/file_naming.dart';

/// 「保留文件原名」的规则验证。
///
/// 以前下载时把空格也换成下划线，`红楼梦 (曹雪芹).pdf` 会变成 `红楼梦_(曹雪芹).pdf`；
/// 这组测试盯住「只清洗真正非法的字符」这条底线，以及重名时不覆盖也不改名。
void main() {
  group('清洗', () {
    test('空格 / 中文 / 括号 / 井号等合法字符原样保留', () {
      expect(FileNaming.sanitize('红楼梦 (曹雪芹).pdf'), '红楼梦 (曹雪芹).pdf');
      expect(FileNaming.sanitize('三体 第1部 - 地球往事.epub'), '三体 第1部 - 地球往事.epub');
      expect(FileNaming.sanitize('C# 入门 #1.pdf'), 'C# 入门 #1.pdf');
      expect(FileNaming.sanitize('a+b&c%d.pdf'), 'a+b&c%d.pdf');
      expect(FileNaming.sanitize("[O'Reilly] Learning.pdf"), "[O'Reilly] Learning.pdf");
      expect(FileNaming.sanitize('书名（全本）【精校】.txt'), '书名（全本）【精校】.txt');
    });

    test('只替换文件系统真正不允许的字符', () {
      expect(FileNaming.sanitize('a/b\\c:d*e?f"g<h>i|j.pdf'), 'a_b_c_d_e_f_g_h_i_j.pdf');
      expect(FileNaming.sanitize('换\n行\t制表.pdf'), '换_行_制表.pdf');
      expect(FileNaming.sanitize('空\u0000字节.pdf'), '空_字节.pdf');
    });

    test('首尾空白与结尾的点被去掉（部分文件系统会吞掉）', () {
      expect(FileNaming.sanitize('  书名.pdf  '), '书名.pdf');
      expect(FileNaming.sanitize('书名.pdf...'), '书名.pdf');
      expect(FileNaming.sanitize('...'), '');
      expect(FileNaming.sanitize('   '), '');
      expect(FileNaming.sanitize(''), '');
    });

    test('超长名字只截断基名，扩展名留着', () {
      final long = '书' * 200;
      final cleaned = FileNaming.sanitize('$long.pdf');
      expect(cleaned.length, FileNaming.maxBaseLength + '.pdf'.length);
      expect(cleaned.endsWith('.pdf'), isTrue);
    });
  });

  group('下载文件名', () {
    test('服务端建议名优先，且保留原样', () {
      expect(
        FileNaming.downloadName(suggested: '红楼梦 (曹雪芹).pdf', urlPath: '/x/1', mimeType: 'application/pdf'),
        '红楼梦 (曹雪芹).pdf',
      );
    });

    test('服务端没给名字时用 URL 末段（百分号解码）', () {
      expect(
        FileNaming.downloadName(
          urlPath: '/files/%E4%B8%89%E4%BD%93%20%E7%AC%AC1%E9%83%A8.epub',
          mimeType: 'application/epub+zip',
        ),
        '三体 第1部.epub',
      );
      expect(
        FileNaming.downloadName(urlPath: '/download/novel.txt', mimeType: 'text/plain'),
        'novel.txt',
      );
    });

    test('没有扩展名时按 MIME 补一个', () {
      expect(
        FileNaming.downloadName(urlPath: '/download/12345', mimeType: 'application/pdf'),
        '12345.pdf',
      );
      expect(
        FileNaming.downloadName(urlPath: '/book', mimeType: 'application/epub+zip'),
        'book.epub',
      );
      // MIME 认不出来就不硬加
      expect(FileNaming.downloadName(urlPath: '/download/12345', mimeType: 'application/octet-stream'),
          '12345');
    });

    test('什么都没有时给一个带时间戳的兜底名', () {
      final name = FileNaming.downloadName(urlPath: '/', mimeType: null);
      expect(name.startsWith('download_'), isTrue);
      expect(FileNaming.hasExtension(name), isFalse);
    });

    test('非法字符仍然被清洗（保留原名的前提是能落盘）', () {
      expect(
        FileNaming.downloadName(suggested: 'a/b:c*d?.pdf', urlPath: '/', mimeType: 'application/pdf'),
        'a_b_c_d_.pdf',
      );
    });

    test('URL 以 / 结尾时退回最后一段有意义的名字，仍比时间戳好认', () {
      // `https://example.com/dir/` 这类地址拿不到真正的文件名，
      // 用路径里最后一段（dir）比 download_1735… 强，扩展名按 MIME 补上
      expect(FileNaming.downloadName(urlPath: '/dir/', mimeType: 'application/pdf'), 'dir.pdf');
      expect(
        FileNaming.downloadName(urlPath: '//', mimeType: 'application/pdf'),
        startsWith('download_'),
      );
    });
  });

  group('重名处理', () {
    test('同名时加 (1)(2)，不覆盖也不改名', () {
      final existing = <String>{'书.pdf', '书 (1).pdf'};
      expect(FileNaming.uniqueName('书.pdf', existing.contains), '书 (2).pdf');
      expect(FileNaming.uniqueName('新书.pdf', existing.contains), '新书.pdf');
    });

    test('没有扩展名时编号加在末尾', () {
      expect(FileNaming.uniqueName('book', (name) => name == 'book'), 'book (1)');
    });

    test('极端情况下用时间戳兜底，仍然保留原名主体', () {
      final name = FileNaming.uniqueName('书.pdf', (_) => true, maxTries: 2);
      expect(name.startsWith('书 ('), isTrue);
      expect(name.endsWith('.pdf'), isTrue);
    });
  });

  group('Content-Disposition 解析（v1.21.39 下载原名）', () {
    // 为什么需要它：Z-Library 这类站是 /dl/xxx → 302 → CDN，WebView 在重定向后
    // 拿不到原始响应头，建议名退化成 URL 末段（用户实测下下来叫 redirection.pdf）。
    // 所以浏览器页会自己再发一次 GET 问服务端 —— 这两件事的解析部分在这里钉死。

    test('RFC 5987：filename*=UTF-8\'\'<percent-encoded>', () {
      // 世界通史 (JOSEPH) (z-library.sk).pdf
      const header = "attachment; filename*=UTF-8''%E4%B8%96%E7%95%8C%E9%80%9A"
          '%E5%8F%B2%20(JOSEPH)%20(z-library.sk).pdf';
      expect(FileNaming.parseContentDisposition(header),
          '世界通史 (JOSEPH) (z-library.sk).pdf');
    });

    test('带引号的普通 filename', () {
      expect(
        FileNaming.parseContentDisposition('attachment; filename="三体 第1部.epub"'),
        '三体 第1部.epub',
      );
    });

    test('不带引号的 filename', () {
      expect(
        FileNaming.parseContentDisposition('attachment; filename=红楼梦.pdf'),
        '红楼梦.pdf',
      );
    });

    test('两种都给时 filename* 赢（RFC 6266）', () {
      const header = 'attachment; filename="fallback.pdf"; '
          "filename*=UTF-8''%E7%9C%9F%E5%90%8D.pdf";
      expect(FileNaming.parseContentDisposition(header), '真名.pdf');
    });

    test('大小写不敏感、参数顺序无关', () {
      expect(
        FileNaming.parseContentDisposition('ATTACHMENT; FILENAME="A.pdf"'),
        'A.pdf',
      );
      expect(
        FileNaming.parseContentDisposition('attachment; size=123; filename="B.pdf"'),
        'B.pdf',
      );
    });

    test('inline / 没有 filename / 空头 → null（调用方自己兜底）', () {
      expect(FileNaming.parseContentDisposition('inline'), isNull);
      expect(FileNaming.parseContentDisposition('attachment'), isNull);
      expect(FileNaming.parseContentDisposition('attachment; size=100'), isNull);
      expect(FileNaming.parseContentDisposition(''), isNull);
      expect(FileNaming.parseContentDisposition(null), isNull);
      expect(FileNaming.parseContentDisposition('   '), isNull);
    });

    test('解析结果会过一遍清洗（非法字符替换、结尾点去掉）', () {
      expect(
        FileNaming.parseContentDisposition('attachment; filename="a/b:c*.pdf"'),
        'a_b_c_.pdf',
      );
      expect(
        FileNaming.parseContentDisposition('attachment; filename="书名.pdf."'),
        '书名.pdf',
      );
    });

    test('过长的名字按既有规则截断（保留扩展名）', () {
      final long = FileNaming.parseContentDisposition(
        'attachment; filename="${'书' * 200}.pdf"',
      );
      expect(long, isNotNull);
      expect(long!.length, FileNaming.maxBaseLength + 4); // 80 + '.pdf'
      expect(long.endsWith('.pdf'), isTrue);
    });

    test('filename* 的引号写法也能吃（部分服务端这么发）', () {
      const header = "attachment; filename*=\"UTF-8''%E4%B9%A6.pdf\"";
      expect(FileNaming.parseContentDisposition(header), '书.pdf');
    });
  });

  group('书名（导入后显示的名字）', () {
    test('去扩展名，其余原样保留', () {
      expect(FileNaming.titleOf('红楼梦 (曹雪芹).pdf'), '红楼梦 (曹雪芹)');
      expect(FileNaming.titleOf('/storage/emulated/0/Download/三体 第1部.epub'), '三体 第1部');
      expect(FileNaming.titleOf('no-extension'), 'no-extension');
      expect(FileNaming.titleOf('.hidden'), '.hidden', reason: '隐藏文件没有扩展名可去');
    });

    test('空名字给「未命名文档」', () {
      expect(FileNaming.titleOf(''), '未命名文档');
      expect(FileNaming.titleOf('   '), '未命名文档');
    });

    test('DocumentService.titleFromPath 与它一致（单一事实来源）', () {
      expect(DocumentService.titleFromPath('/a/b/红楼梦 (曹雪芹).pdf'), '红楼梦 (曹雪芹)');
      expect(DocumentService.titleFromPath(r'C:\books\三体 第1部.epub'), '三体 第1部');
    });
  });
}
