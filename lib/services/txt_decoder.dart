import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';

/// 解码结果：文本 + 实际用的编码（编码名会写进诊断日志）
class TxtDecoding {
  const TxtDecoding({
    required this.text,
    required this.encoding,
    this.hadBom = false,
    this.corrected = false,
  });

  final String text;

  /// 展示用的编码名：UTF-8 / GBK / Big5 / UTF-16LE / UTF-16BE / Latin-1
  final String encoding;

  /// 是否带 BOM
  final bool hadBom;

  /// 是否是「UTF-8 走不通、自动换了别的编码」的情况
  final bool corrected;

  bool get isUtf8 => encoding == TxtDecoder.utf8Name;

  /// 诊断日志里的一行说明
  String get description =>
      '$encoding${hadBom ? '（带 BOM）' : ''}${corrected ? '（自动纠正）' : ''}';

  @override
  String toString() => description;
}

/// TXT 编码探测与解码
///
/// 为什么需要它：原来只有「严格 UTF-8，失败就 Latin-1」两条路，
/// 于是一本 GBK 小说有两种结局 ——
/// 1. 字节序列不是合法 UTF-8（多数情况）→ Latin-1 逐字节硬解 → **整本乱码**；
/// 2. 字节序列**恰好**是合法 UTF-8（中文少、文本短的文件很容易）→ 不抛异常、
///    悄悄解成「拉丁字母 + 注音符号」那种乱码 —— 这就是「有概率乱码」的来源。
///
/// 现在的做法：先看 BOM，再严格校验 UTF-8；UTF-8 解出来但「像乱码」时，
/// 用 GBK / Big5 / Latin-1 各解一遍按「像不像正常正文」打分选赢家。
/// 全部纯 Dart（解析跑在 isolate 里，不能用平台通道）。
class TxtDecoder {
  TxtDecoder._();

  static const String utf8Name = 'UTF-8';
  static const String gbkName = 'GBK';
  static const String big5Name = 'Big5';
  static const String utf16LeName = 'UTF-16LE';
  static const String utf16BeName = 'UTF-16BE';
  static const String latin1Name = 'Latin-1';

  /// 候选编码打分只看前这么多字节：几 MB 的小说没必要整本解好几遍
  static const int sampleBytes = 64 * 1024;

  /// 换用其它编码需要的领先分差（避免把正常文本误判成 GBK）
  static const double switchMargin = 0.15;

  /// GBK / Big5：非法字节解成 U+FFFD，不抛异常
  static const GbkCodec _gbk = GbkCodec(allowInvalid: true);
  static const Big5Codec _big5 = Big5Codec(allowInvalid: true);

  /// 可手动指定的编码名（设置页 / 诊断用）
  static const List<String> supportedEncodings = <String>[
    utf8Name,
    gbkName,
    big5Name,
    utf16LeName,
    utf16BeName,
    latin1Name,
  ];

  /// 解码；[assumeEncoding] 指定时直接按它解（给手动纠正留口子）
  static TxtDecoding decode(List<int> bytes, {String? assumeEncoding}) {
    if (bytes.isEmpty) return const TxtDecoding(text: '', encoding: utf8Name);

    if (assumeEncoding != null && assumeEncoding.trim().isNotEmpty) {
      final forced = _byName(bytes, assumeEncoding);
      if (forced != null) return forced;
    }

    // 1) BOM 最可靠，直接照它解
    final bom = _decodeByBom(bytes);
    if (bom != null) return bom;

    final sample = bytes.length > sampleBytes ? bytes.sublist(0, sampleBytes) : bytes;

    // 2) 严格 UTF-8：能过且不像乱码就是它（绝大多数文件走这条快路）
    String? utf8Text;
    try {
      utf8Text = utf8.decode(bytes);
    } catch (_) {
      utf8Text = null;
    }
    if (utf8Text != null && !looksLikeMojibake(utf8Text)) {
      return TxtDecoding(text: _stripBom(utf8Text), encoding: utf8Name);
    }

    // 3) 没有 BOM 的 UTF-16：NUL 分布只是「加分项」，最终仍然按分数选
    //    （纯中文的 UTF-16 里几乎没有 NUL 字节，只看 NUL 会漏判）
    final nulHint = _utf16Hint(bytes);

    // 4) 候选编码按分数选：GBK / Big5 / Latin-1 / UTF-16LE / UTF-16BE
    final candidates = <_Candidate>[
      _candidate(gbkName, sample, (data) => _gbk.decode(data), prior: 0.05),
      _candidate(big5Name, sample, (data) => _big5.decode(data)),
      _candidate(latin1Name, sample, (data) => latin1.decode(data, allowInvalid: true)),
      _candidate(
        utf16LeName,
        sample,
        (data) => _decodeUtf16(data, littleEndian: true),
        prior: nulHint == _Utf16Hint.little ? 0.6 : 0,
      ),
      _candidate(
        utf16BeName,
        sample,
        (data) => _decodeUtf16(data, littleEndian: false),
        prior: nulHint == _Utf16Hint.big ? 0.6 : 0,
      ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final winner = candidates.first;

    // UTF-8 合法时它也是候选：别的编码要明显更好才换（避免误判西文文件）
    if (utf8Text != null) {
      final utf8Score = _scoreSample(utf8Text);
      if (winner.score < utf8Score + switchMargin) {
        return TxtDecoding(text: _stripBom(utf8Text), encoding: utf8Name);
      }
      return TxtDecoding(
        text: _decodeFull(bytes, winner.name),
        encoding: winner.name,
        corrected: true,
      );
    }

    // UTF-8 不合法：Latin-1 是「不会更糟」的兜底，别的编码得领先才用
    final latin = candidates.firstWhere((item) => item.name == latin1Name);
    if (winner.name != latin1Name && winner.score < latin.score + switchMargin) {
      return TxtDecoding(
        text: _decodeFull(bytes, latin1Name),
        encoding: latin1Name,
        corrected: true,
      );
    }
    return TxtDecoding(text: _decodeFull(bytes, winner.name), encoding: winner.name, corrected: true);
  }

  /// 判断「这段 UTF-8 解码结果像不像把 GBK 当 UTF-8 读出来的乱码」
  ///
  /// 两个条件同时成立才算：读起来不像正常正文（打分低），
  /// **并且**混着两个以上「异种文字块」。真实的俄语 / 希腊语文件只会集中在一个
  /// 文字块里，法语这类西文打分很高，所以都不会被误判。
  static bool looksLikeMojibake(String text) {
    var total = 0;
    var cjk = 0;
    final groups = <int>{};
    for (final rune in text.runes) {
      if (rune <= 0x7F) continue;
      total++;
      if (_isCjk(rune) || _isCjkPunctuation(rune)) {
        cjk++;
        continue;
      }
      final group = _scriptGroup(rune);
      if (group != 0) groups.add(group);
    }
    if (total < 8) return false; // 太短，不下结论
    if (cjk * 20 >= total) return false; // 中文占比够高，正常
    if (groups.length < 2) return false; // 只有一个文字块：真实外语文件
    return _scoreSample(text) < 0.5; // 读起来不像正常正文
  }

  /// 给一段候选文本打分：越像正常中文 / 西文正文分越高
  static double _scoreSample(String text) {
    if (text.isEmpty) return -1;
    var total = 0;
    var cjk = 0;
    var ascii = 0;
    var suspicious = 0;
    var weird = 0;
    var invalid = 0;
    for (final rune in text.runes) {
      total++;
      if (rune == 0xFFFD) {
        invalid++;
        continue;
      }
      if (rune <= 0x7F) {
        // 控制字符（除常见空白）算异常
        if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
          weird++;
        } else {
          ascii++;
        }
        continue;
      }
      if (_isCjk(rune) || _isCjkPunctuation(rune)) {
        cjk++;
        continue;
      }
      if (_scriptGroup(rune) != 0) {
        suspicious++;
        continue;
      }
      if (_isCommonPunctuation(rune)) {
        ascii++;
        continue;
      }
      weird++; // 私用区、未分配、其它罕见块
    }
    if (total == 0) return -1;
    final raw = cjk * 3.0 + ascii * 1.0 + suspicious * 0.15 - weird * 1.5 - invalid * 3.0;
    return raw / total - invalid * 2.0 / (total + 1);
  }

  static _Candidate _candidate(
    String name,
    List<int> sample,
    String Function(List<int>) decoder, {
    double prior = 0,
  }) {
    var text = '';
    try {
      text = decoder(sample);
    } catch (_) {
      text = '';
    }
    final invalid = '\uFFFD'.allMatches(text).length;
    final score = _scoreSample(text) + prior - invalid * 2.0 / (text.length + 1);
    return _Candidate(name: name, score: score);
  }

  static String _decodeFull(List<int> bytes, String name) {
    try {
      switch (name) {
        case gbkName:
          return _gbk.decode(bytes);
        case big5Name:
          return _big5.decode(bytes);
        case latin1Name:
          return latin1.decode(bytes, allowInvalid: true);
        case utf16LeName:
          return _decodeUtf16(bytes, littleEndian: true);
        case utf16BeName:
          return _decodeUtf16(bytes, littleEndian: false);
        default:
          return _stripBom(utf8.decode(bytes, allowMalformed: true));
      }
    } catch (_) {
      return '';
    }
  }

  static TxtDecoding? _byName(List<int> bytes, String name) {
    final normalized = name.trim().toLowerCase();
    switch (normalized) {
      case 'utf-8':
      case 'utf8':
        return TxtDecoding(
          text: _stripBom(utf8.decode(bytes, allowMalformed: true)),
          encoding: utf8Name,
        );
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
        return TxtDecoding(text: _decodeFull(bytes, gbkName), encoding: gbkName);
      case 'big5':
      case 'big-5':
        return TxtDecoding(text: _decodeFull(bytes, big5Name), encoding: big5Name);
      case 'latin-1':
      case 'latin1':
      case 'iso-8859-1':
        return TxtDecoding(text: _decodeFull(bytes, latin1Name), encoding: latin1Name);
      case 'utf-16le':
        return TxtDecoding(text: _decodeFull(bytes, utf16LeName), encoding: utf16LeName);
      case 'utf-16be':
        return TxtDecoding(text: _decodeFull(bytes, utf16BeName), encoding: utf16BeName);
    }
    return null;
  }

  /// BOM 判定
  static TxtDecoding? _decodeByBom(List<int> bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return TxtDecoding(
        text: _stripBom(utf8.decode(bytes.sublist(3), allowMalformed: true)),
        encoding: utf8Name,
        hadBom: true,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return TxtDecoding(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: true),
        encoding: utf16LeName,
        hadBom: true,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return TxtDecoding(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: false),
        encoding: utf16BeName,
        hadBom: true,
      );
    }
    return null;
  }

  /// 没有 BOM 的 UTF-16 提示：靠 NUL 字节分布猜字节序
  ///
  /// 只作为打分时的**加分项**，不做最终判决 —— 纯中文的 UTF-16 里几乎没有 NUL
  /// 字节（汉字两字节都不为 0），只看 NUL 会漏判。
  static _Utf16Hint _utf16Hint(List<int> bytes) {
    if (bytes.length < 16) return _Utf16Hint.none;
    final limit = bytes.length > sampleBytes ? sampleBytes : bytes.length;
    var evenNul = 0;
    var oddNul = 0;
    var pairs = 0;
    for (var i = 0; i + 1 < limit; i += 2) {
      pairs++;
      if (bytes[i] == 0) evenNul++;
      if (bytes[i + 1] == 0) oddNul++;
    }
    if (pairs == 0) return _Utf16Hint.none;
    final evenRatio = evenNul / pairs;
    final oddRatio = oddNul / pairs;
    if (oddRatio > 0.3 && oddRatio > evenRatio * 3) return _Utf16Hint.little;
    if (evenRatio > 0.3 && evenRatio > oddRatio * 3) return _Utf16Hint.big;
    return _Utf16Hint.none;
  }

  /// 最小 UTF-16 解码（dart:convert 没有内置 UTF-16；含代理对处理）
  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final buffer = StringBuffer();
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian ? (bytes[i] | (bytes[i + 1] << 8)) : ((bytes[i] << 8) | bytes[i + 1]));
    }
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit == 0xFEFF) continue; // BOM
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < units.length) {
        final low = units[i + 1];
        if (low >= 0xDC00 && low <= 0xDFFF) {
          buffer.writeCharCode(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
          i++;
          continue;
        }
      }
      if (unit >= 0xD800 && unit <= 0xDFFF) continue; // 孤立代理：丢掉
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  static String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;

  static bool _isCjk(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本区
      (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
      (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意
      (rune >= 0x20000 && rune <= 0x2FA1F); // 扩展 B 及以后

  static bool _isCjkPunctuation(int rune) =>
      (rune >= 0x3000 && rune <= 0x303F) || // 、。《》…
      (rune >= 0xFF00 && rune <= 0xFFEF); // 全角字符

  static bool _isCommonPunctuation(int rune) =>
      (rune >= 0x2010 && rune <= 0x203B) || // – — ‘ ’ “ ” …
      rune == 0x00B7 ||
      rune == 0x00A0 ||
      rune == 0x2022;

  /// 异种文字块编号；0 表示不算（常见标点等）
  ///
  /// 乱码的特征是**同时**出现多个块，而真实外语文件只会集中在一个块里。
  static int _scriptGroup(int rune) {
    if (rune >= 0x0080 && rune <= 0x00BF) return 1; // C1 控制符 / Latin-1 标点（乱码里很常见）
    if (rune >= 0x00C0 && rune <= 0x00FF) return 1; // 拉丁补充字母
    if (rune >= 0x0100 && rune <= 0x024F) return 2; // 拉丁扩展 A/B
    if (rune >= 0x0250 && rune <= 0x02FF) return 3; // 国际音标 / 修饰字母
    if (rune >= 0x0300 && rune <= 0x036F) return 4; // 组合附加符号
    if (rune >= 0x0370 && rune <= 0x03FF) return 5; // 希腊
    if (rune >= 0x0400 && rune <= 0x04FF) return 6; // 西里尔
    if (rune >= 0x0590 && rune <= 0x06FF) return 7; // 希伯来 / 阿拉伯
    if (rune >= 0x0700 && rune <= 0x0EFF) return 8; // 叙利亚、天城文、泰文等
    if (rune >= 0x1E00 && rune <= 0x1EFF) return 9; // 拉丁扩展附加
    if (rune >= 0xE000 && rune <= 0xF8FF) return 10; // 私用区（乱码常见）
    return 0;
  }
}

/// 无 BOM 时的字节序提示
enum _Utf16Hint { none, little, big }

class _Candidate {
  const _Candidate({required this.name, required this.score});

  final String name;
  final double score;
}
