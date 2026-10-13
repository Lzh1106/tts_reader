import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/document_service.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/txt_decoder.dart';

/// 设备层验证：**GBK / UTF-16 的 TXT 在真机上不再乱码**
///
/// 重点是走 isolate 那条真实路径（`parseAsync`）：编码探测用的 enough_convert
/// 是纯 Dart 实现，必须在 isolate 里也能跑（解析 isolate 不能用任何插件）。
///
/// 跑法：flutter test integration_test/txt_encoding_verify_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const gbkCodec = GbkCodec();
  const text =
      '第一章 风起\n'
      '天还没亮他就出门了，路上一个人也没有。\n'
      '“今天大概会下雨吧。”他抬头看了看天。\n'
      '第二章 雨落\n'
      '雨下了整夜，他站在门口没动。\n';

  List<int> utf16Le(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      bytes..add(unit & 0xFF)..add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  Future<ParseResult> parseBytes(Directory dir, List<int> bytes, String name) async {
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    final task = DocumentService.parseAsync(
      Document(
        id: name,
        title: name,
        path: file.path,
        type: DocumentType.txt,
        importedAt: DateTime.now(),
      ),
    );
    return task.result;
  }

  testWidgets('GBK 与 UTF-16 的 TXT 在真机上解析正常', (tester) async {
    await StorageService.instance.init();
    final dir = await Directory.systemTemp.createTemp('tts_encoding');

    // 1) GBK：以前会整本乱码
    final gbk = await parseBytes(dir, gbkCodec.encode(text), 'gbk.txt');
    // ignore: avoid_print
    print('DEVICE_VERIFY[encoding] GBK → encoding=${gbk.encoding} 章=${gbk.document.chapters.length} '
        '首段=${gbk.document.chapters.first.paragraphs.first.text}');
    expect(gbk.encoding, TxtDecoder.gbkName);
    expect(gbk.document.chapters.length, 2);
    expect(gbk.document.chapters.first.title, '第一章 风起');
    expect(gbk.document.chapters.first.paragraphs.first.text, '天还没亮他就出门了，路上一个人也没有。');
    expect(gbk.document.plainText, contains('雨下了整夜'));

    // 2) UTF-16（无 BOM）：以前会按 Latin-1 解成乱码
    final utf16 = await parseBytes(dir, utf16Le(text), 'utf16.txt');
    // ignore: avoid_print
    print('DEVICE_VERIFY[encoding] UTF-16 → encoding=${utf16.encoding} '
        '章=${utf16.document.chapters.length} 首段=${utf16.document.chapters.first.paragraphs.first.text}');
    expect(utf16.encoding, TxtDecoder.utf16LeName);
    expect(utf16.document.chapters.first.paragraphs.first.text, contains('天还没亮'));

    // 3) UTF-8：编码报 UTF-8，内容一字不差（别把好文件弄坏）
    final utf8Result = await parseBytes(dir, utf8.encode(text), 'utf8.txt');
    // ignore: avoid_print
    print('DEVICE_VERIFY[encoding] UTF-8 → encoding=${utf8Result.encoding} '
        '章=${utf8Result.document.chapters.length}');
    expect(utf8Result.encoding, TxtDecoder.utf8Name);
    expect(utf8Result.document.chapters.first.paragraphs.first.text, '天还没亮他就出门了，路上一个人也没有。');

    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });
}
