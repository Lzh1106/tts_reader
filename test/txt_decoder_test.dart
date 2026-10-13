import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/txt_decoder.dart';

/// TXT 乱码修复验证。
///
/// 修复前的两条路：严格 UTF-8 成功就用它，失败就 Latin-1 逐字节硬解。
/// 于是 GBK 小说要么整本乱码，要么（字节恰好合法时）悄悄解成「拉丁字母 + 注音」
/// 那种乱码 —— 后者就是「有概率乱码」的来源。这组测试盯住每一种情况。
void main() {
  const gbkCodec = GbkCodec();
  const big5Codec = Big5Codec();

  /// 一段典型的中文小说正文（包含全角标点）
  const sample =
      '第一章 风起\n'
      '天还没亮他就出门了，路上一个人也没有。\n'
      '“今天大概会下雨吧。”他抬头看了看天。\n'
      '第二章 雨落\n'
      '雨下了整夜，他站在门口没动。\n';

  List<int> utf8Bytes([String text = sample]) => utf8.encode(text);
  List<int> gbkBytes([String text = sample]) => gbkCodec.encode(text);
  List<int> big5Bytes([String text = sample]) => big5Codec.encode(text);

  List<int> utf16Bytes(String text, {required bool littleEndian, bool bom = false}) {
    final bytes = <int>[];
    if (bom) bytes.addAll(littleEndian ? <int>[0xFF, 0xFE] : <int>[0xFE, 0xFF]);
    for (final unit in text.codeUnits) {
      if (littleEndian) {
        bytes..add(unit & 0xFF)..add((unit >> 8) & 0xFF);
      } else {
        bytes..add((unit >> 8) & 0xFF)..add(unit & 0xFF);
      }
    }
    return bytes;
  }

  group('编码探测', () {
    test('UTF-8（无 BOM）原样通过', () {
      final result = TxtDecoder.decode(utf8Bytes());
      expect(result.encoding, TxtDecoder.utf8Name);
      expect(result.text, sample);
      expect(result.corrected, isFalse);
    });

    test('UTF-8 BOM 被剥掉且不残留 \uFEFF', () {
      final result = TxtDecoder.decode(<int>[0xEF, 0xBB, 0xBF, ...utf8Bytes()]);
      expect(result.encoding, TxtDecoder.utf8Name);
      expect(result.hadBom, isTrue);
      expect(result.text.startsWith('\uFEFF'), isFalse);
      expect(result.text, sample);
    });

    test('GBK：以前会整本乱码，现在正确解出', () {
      final result = TxtDecoder.decode(gbkBytes());
      expect(result.encoding, TxtDecoder.gbkName);
      expect(result.text, sample);
      expect(result.corrected, isTrue);
    });

    test('Big5：繁体中文也能认出来', () {
      const traditional = '第一章 風起\n他抬頭看了看天，雨還沒停。\n第二章 雨落\n';
      final result = TxtDecoder.decode(big5Bytes(traditional));
      expect(result.encoding, TxtDecoder.big5Name);
      expect(result.text, traditional);
    });

    test('UTF-16LE / BE 有 BOM 时按 BOM 解', () {
      final le = TxtDecoder.decode(utf16Bytes(sample, littleEndian: true, bom: true));
      expect(le.encoding, TxtDecoder.utf16LeName);
      expect(le.text, sample);

      final be = TxtDecoder.decode(utf16Bytes(sample, littleEndian: false, bom: true));
      expect(be.encoding, TxtDecoder.utf16BeName);
      expect(be.text, sample);
    });

    test('UTF-16 没有 BOM 时靠 NUL 分布判断', () {
      final le = TxtDecoder.decode(utf16Bytes(sample, littleEndian: true));
      expect(le.encoding, TxtDecoder.utf16LeName);
      expect(le.text, sample);
    });

    test('纯 ASCII 文本不会被动成 GBK', () {
      const ascii = 'Chapter 1\nThe road was empty.\nChapter 2\nIt rained all night.\n';
      final result = TxtDecoder.decode(utf8Bytes(ascii));
      expect(result.encoding, TxtDecoder.utf8Name);
      expect(result.text, ascii);
    });

    test('真实的西文（非中文）不会被误判成中文编码', () {
      const russian = 'Глава первая. Он вышел из дома рано утром, '
          'на улице никого не было. Глава вторая. Дождь шёл всю ночь.';
      final result = TxtDecoder.decode(utf8Bytes(russian));
      expect(result.encoding, TxtDecoder.utf8Name, reason: '西里尔文本应当保持 UTF-8');
      expect(result.text, russian);

      const greek = 'Κεφάλαιο πρώτο. Βγήκε από το σπίτι νωρίς το πρωί.';
      expect(TxtDecoder.decode(utf8Bytes(greek)).encoding, TxtDecoder.utf8Name);

      const french = 'Chapitre un. Il sortit de la maison très tôt, '
          'il n’y avait personne dans la rue. Chapitre deux. Il pleuvait.';
      expect(TxtDecoder.decode(utf8Bytes(french)).encoding, TxtDecoder.utf8Name);
    });

    test('空文件 / 单个字节都不抛异常', () {
      expect(TxtDecoder.decode(<int>[]).text, '');
      expect(TxtDecoder.decode(<int>[0x41]).text, 'A');
      expect(() => TxtDecoder.decode(List<int>.generate(64, (i) => i)), returnsNormally);
    });

    test('可以指定编码（手动纠正的口子）', () {
      final result = TxtDecoder.decode(gbkBytes(), assumeEncoding: 'GBK');
      expect(result.encoding, TxtDecoder.gbkName);
      expect(result.text, sample);

      final forced = TxtDecoder.decode(utf8Bytes(), assumeEncoding: 'latin1');
      expect(forced.encoding, TxtDecoder.latin1Name);
      expect(forced.text, isNot(sample), reason: '强制按 Latin-1 解就是乱码，符合预期');
    });
  });

  group('乱码特征识别', () {
    test('GBK 当 UTF-8 读出来的那种文本会被判为乱码，并自动按 GBK 重解', () {
      // 造一段「GBK 字节恰好全是合法 UTF-8」的文本：这让严格 UTF-8 不抛异常，
      // 修复前会直接当成 UTF-8 用掉 —— 这就是「有概率乱码」。
      final mojibake = _utf8SafeGbkMojibake();
      expect(mojibake, isNotNull, reason: '测试数据应当能构造出来');
      expect(TxtDecoder.looksLikeMojibake(mojibake!), isTrue);
    });

    test('短文本不下结论（几个字的文件不值得猜编码）', () {
      expect(TxtDecoder.looksLikeMojibake('ģ'), isFalse);
    });

    test('正常中文 / 西文 / 中英混排都不算乱码', () {
      expect(TxtDecoder.looksLikeMojibake(sample), isFalse);
      expect(TxtDecoder.looksLikeMojibake('Chapter 1: The road was empty.'), isFalse);
      expect(TxtDecoder.looksLikeMojibake('第一章 Chapter One 出发。'), isFalse);
      expect(TxtDecoder.looksLikeMojibake('Привет, мир! Как дела?'), isFalse);
      expect(TxtDecoder.looksLikeMojibake(''), isFalse);
      expect(TxtDecoder.looksLikeMojibake('短'), isFalse);
    });
  });

  group('走完整解析链路', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tts_encoding_');
    });

    tearDown(() async {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<ParseResult> parseBytes(List<int> bytes, {String name = 'book.txt'}) async {
      final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return DocumentService.parse(
        Document(
          id: name,
          title: name,
          path: file.path,
          type: DocumentType.txt,
          importedAt: DateTime(2024),
        ),
      );
    }

    test('GBK 小说：正文与章节都正常，且报告编码', () async {
      final result = await parseBytes(gbkBytes());
      expect(result.encoding, TxtDecoder.gbkName);
      expect(result.document.chapters.length, 2);
      expect(result.document.chapters.first.title, '第一章 风起');
      expect(result.document.chapters.first.paragraphs.first.text, '天还没亮他就出门了，路上一个人也没有。');
      expect(result.document.chapters.last.paragraphs.first.text, contains('雨下了整夜'));
    });

    test('UTF-8 小说：编码报 UTF-8，文字与原文一致', () async {
      final result = await parseBytes(utf8Bytes());
      expect(result.encoding, TxtDecoder.utf8Name);
      expect(result.document.chapters.first.paragraphs.first.text, '天还没亮他就出门了，路上一个人也没有。');
    });

    test('UTF-16 小说（无 BOM）也能读', () async {
      final result = await parseBytes(utf16Bytes(sample, littleEndian: true));
      expect(result.encoding, TxtDecoder.utf16LeName);
      expect(result.document.chapters.length, 2);
      expect(result.document.chapters.first.paragraphs.first.text, contains('天还没亮'));
    });

    test('isolate 路径（parseAsync）同样带得回编码', () async {
      final file = File('${dir.path}/async.txt')..writeAsBytesSync(gbkBytes());
      final task = DocumentService.parseAsync(
        Document(
          id: 'async',
          title: 'async',
          path: file.path,
          type: DocumentType.txt,
          importedAt: DateTime(2024),
        ),
      );
      final result = await task.result;
      expect(result.encoding, TxtDecoder.gbkName);
      expect(result.document.chapters.first.title, '第一章 风起');
    });

    test('GBK 英文小说（没有中文）也不会被 Latin-1 弄成乱码', () async {
      const english = 'Chapter One\nHe left the house before dawn.\n\n'
          'Chapter Two\nIt rained all night.\n';
      final result = await parseBytes(gbkBytes(english));
      // GBK 兼容 ASCII，所以这种文件本来就是「能读」的
      expect(result.document.plainText, contains('He left the house before dawn.'));
      expect(result.document.chapters.length, 2);
    });
  });
}

/// 构造一段「GBK 字节恰好全部是合法 UTF-8」的文本，用来复现隐蔽的乱码场景
///
/// 做法：从 GBK 表里挑出双字节都落在 UTF-8 合法范围内的字。
/// 注意要多挑一些字（≥8 个）——太少的话「文本太短不下结论」的保护会生效，
/// 这本身是合理行为（几个字的文件不值得为它猜编码）。
/// 返回按 UTF-8 解出来的（错误）文本；构造不出来时返回 null。
String? _utf8SafeGbkMojibake() {
  const gbkCodec = GbkCodec();
  final picked = <int>[];
  final chars = <String>[];
  // 遍历常用汉字，找出 GBK 编码恰好是「110xxxxx 10xxxxxx」两字节的字
  for (var rune = 0x4E00; rune <= 0x9FA5 && chars.length < 14; rune++) {
    final char = String.fromCharCode(rune);
    List<int> bytes;
    try {
      bytes = gbkCodec.encode(char);
    } catch (_) {
      continue;
    }
    if (bytes.length != 2) continue;
    final first = bytes[0];
    final second = bytes[1];
    final validUtf8 = first >= 0xC2 && first <= 0xDF && second >= 0x80 && second <= 0xBF;
    if (validUtf8) {
      picked.addAll(bytes);
      chars.add(char);
    }
  }
  if (chars.length < 8) return null;
  try {
    return utf8.decode(picked);
  } catch (_) {
    return null;
  }
}
