import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/document.dart';
import '../models/pdf_line_box.dart';
import '../models/structured_document.dart';

/// 解析结果的持久化缓存（大文件性能的关键一层）
///
/// 为什么需要它：解析一本书要读整个文件、解码编码、切章、分句、逐页抽 PDF 文字层，
/// 一本几十 MB 的书要几十秒。但**同一份文件每次打开的结果完全一样** ——
/// 只有第一次需要真解析，之后直接从磁盘把结构读回来即可（毫秒级）。
///
/// 失效判据：文件路径、字节数、修改时间任一变化即视为换了文件；
/// 缓存格式版本与解析器版本（`DocumentService.parseRevision`）也参与判据，
/// 所以「升级应用后解析规则变了」不会读到旧结构。
///
/// 存的是**紧凑二进制**而不是 JSON：一本 300 万字、20 万句的小说，
/// JSON 要几百 MB 且编解码要好几秒，二进制只是它的几分之一。
///
/// 注意：这个类只用 `dart:io` 与 `dart:convert`，可以在解析 isolate 里直接用。
class DocumentCache {
  DocumentCache._();

  /// 缓存格式版本：字段布局改动时必须 +1（旧缓存会因版本不符被丢弃）
  /// 缓存格式版本
  ///
  /// - v2 → **v3**（v1.21.34 / L2b-1）：载荷尾部**追加**「行表分块索引」。
  ///   ⚠️ 读到 v2 缓存一律当 miss（`version != formatVersion → null`），
  ///   **不做迁移** —— 首次打开会走一次全量解析，这是**预期行为**，不是 bug。
  /// - 追加而非插入：已有字段偏移全不变，写读自洽即可。
  static const int formatVersion = 3;

  static const List<int> _magic = <int>[0x54, 0x54, 0x53, 0x43]; // "TTSC"

  /// 缓存文件扩展名
  static const String extension = '.ttsc';

  /// 单份缓存的体积上限：超过就不写（几千页的 PDF 行表可能很大）
  static const int maxCacheBytes = 96 * 1024 * 1024;

  /// 头部布局（共 14 字节，全部小端）：
  /// `0..3` magic、`4..5` 格式版本、`6..9` 载荷长度、`10..13` 载荷 CRC-32
  static const int headerBytes = 14;
  static const int _versionOffset = 4;
  static const int _lengthOffset = 6;
  static const int _crcOffset = 10;

  /// 磁盘上一份缓存的「新鲜度指纹」
  ///
  /// 由文件路径 + 字节数 + 修改时间组成：用户换了同名文件、重新下载、
  /// 或者编辑器改了内容，指纹都会变，缓存自动失效。
  static String identityOf(Document document) {
    int length = 0;
    int modified = 0;
    try {
      final file = File(document.path);
      if (file.existsSync()) {
        length = file.lengthSync();
        modified = file.lastModifiedSync().millisecondsSinceEpoch;
      }
    } catch (_) {
      // 文件读不到（权限 / 已删除）：指纹退化成只有路径，
      // 缓存仍会在下次成功解析后被新指纹覆盖
    }
    return identityOfFile(document.path, length, modified);
  }

  /// 文件指纹（把 [length] / [modifiedMs] 拆出来便于单测直接构造）
  static String identityOfFile(String path, int length, int modifiedMs) =>
      '$path|$length|$modifiedMs';

  /// 文档 id 清洗（主缓存名与块文件名共用；v1.21.33 从 [fileNameFor] 抽出来）
  static String _safeName(String documentId) =>
      documentId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 缓存主文件名（按文档 id 稳定）
  static String fileNameFor(String documentId) => '${_safeName(documentId)}$extension';

  // ---------------- 分块行表（v1.21.33 / L2a） ----------------

  /// 分块行表：每块页数（812 页 → 17 块，每块约 200–300 KB）
  static const int linesChunkPages = 50;

  /// 分块行表文件后缀
  static const String linesExtension = '.ttsl';

  /// 块文件头：魔数（'TTL1'）+ 块格式版本
  ///
  /// 单独带版本号是为了将来看清"这是分块文件"而不是主缓存 —— 主缓存的
  /// [formatVersion] 变了不该连带让块文件失效。
  static const int _chunkMagic = 0x31544C54;
  static const int _chunkVersion = 1;

  /// 分块行表文件名：`<docId>.lines.<chunk>.ttsl`
  static String linesChunkFileNameFor(String documentId, int chunk) =>
      '${_safeName(documentId)}.lines.$chunk$linesExtension';

  /// 分块行表完整路径（调用方只拿目录 + 文档 id，不自己拼文件名）
  ///
  /// 清洗规则与 [writeLineChunks] / [fileNameFor] 共用同一份 [_safeName]：
  /// 外面自己拼一次就会和写侧对不上（文档 id 里带空格 / 中文的文件名会写歪）。
  static String linesChunkPathFor(String dirPath, String documentId, int chunk) =>
      '$dirPath${Platform.pathSeparator}'
      '${linesChunkFileNameFor(documentId, chunk)}';

  /// 块读缓存上限（约 2MB，**按字节数**、不按块数）
  ///
  /// 为什么按字节：50 页一块的普通 PDF 约 200–300 KB，但**注释密集的页面可能翻倍**，
  /// 按块数设上限会出现"两块就够了、两块爆内存"两种极端。
  /// 为什么不缓存整块：用户在同一块内来回翻页会**反复读同一个文件** ✗
  static const int maxChunkCacheBytes = 2 * 1024 * 1024;

  /// 块号 → (载荷字节数, 行表)：值为 `null` 表示"这一块确认读不出来"（负缓存）
  ///
  /// 缓存的是**解码后的行表**：翻页时再用的是它，不是字节。
  /// Map 的迭代顺序 = 插入顺序 → **淘汰最旧的**直接取 `keys.first`。
  static final Map<String, _CachedChunk?> _chunkCache = <String, _CachedChunk?>{};
  static int _chunkCacheBytes = 0;

  /// 读块的文件级计数（**只给测试看**）：翻页"到底碰了几次盘"靠它断言
  static int _blockReadCount = 0;
  static int _blockReadBytes = 0;

  /// 读盘次数（含缺块 / 坏块的那次尝试；命中块读缓存不计）
  @visibleForTesting
  static int get blockReadCount => _blockReadCount;

  /// 读盘字节数（只统计真正从文件读出来的字节）
  @visibleForTesting
  static int get blockReadBytes => _blockReadBytes;

  /// 当前块读缓存占用字节数（**只给测试看**）
  @visibleForTesting
  static int get blockCacheBytesForTest => _chunkCacheBytes;

  /// 清空块读缓存与计数（**只给测试用**：静态状态会跨用例串味）
  @visibleForTesting
  static void resetBlockCacheForTest() {
    _chunkCache.clear();
    _chunkCacheBytes = 0;
    _blockReadCount = 0;
    _blockReadBytes = 0;
  }

  /// 按「缓存目录 + 文档 id + 块号」读一块行表（走 [readLineChunk] 同一套校验）
  ///
  /// 与 [readLineChunk] 的分工：那个只认完整路径，供已有调用方与单测直接用；
  /// 这里负责拼路径 + 查块读缓存 + 记账，阅读页走这一条。
  static Map<int, List<PdfLineBox>>? readLineChunkByName(
    String dirPath,
    String documentId,
    int chunk,
  ) {
    if (dirPath.isEmpty) return null;
    final String key = '$dirPath|${_safeName(documentId)}|$chunk';
    if (_chunkCache.containsKey(key)) {
      return _chunkCache[key]?.lines; // 命中（含"确认读不出来"的负缓存）
    }
    final String path = linesChunkPathFor(dirPath, documentId, chunk);
    _blockReadCount++;
    final File file = File(path);
    int bytes = 0;
    try {
      if (file.existsSync()) bytes = file.lengthSync();
    } catch (_) {
      bytes = 0;
    }
    final Map<int, List<PdfLineBox>>? lines = readLineChunk(path);
    if (lines == null) {
      // 缺块 / 坏块：也记一次读盘尝试，并做负缓存 ——
      // 否则同一块反复读不出来时会每次都去碰盘（点句会跟着卡）。
      _blockReadBytes += bytes;
      _putChunk(key, null);
      return null;
    }
    // 载荷字节数按"解码后的行表"估：文本长度 + 4 个 double 的包围盒 + 每页表头
    int payload = 16;
    for (final MapEntry<int, List<PdfLineBox>> page in lines.entries) {
      payload += 16;
      for (final PdfLineBox box in page.value) {
        payload += box.text.length * 2 + 32 + 16;
      }
    }
    _blockReadBytes += bytes > 0 ? bytes : payload;
    _putChunk(key, _CachedChunk(payload, lines));
    return lines;
  }

  /// 放进块读缓存并按字节数兜底淘汰最旧的（正在用的那块由调用方先取出引用，不受影响）
  static void _putChunk(String key, _CachedChunk? entry) {
    final _CachedChunk? old = _chunkCache.remove(key);
    if (old != null) _chunkCacheBytes -= old.bytes;
    _chunkCache[key] = entry;
    if (entry != null) _chunkCacheBytes += entry.bytes;
    while (_chunkCacheBytes > maxChunkCacheBytes && _chunkCache.length > 1) {
      final String oldest = _chunkCache.keys.first;
      if (oldest == key) break; // 只留刚放进来那一块，绝不把当前块淘汰掉
      final _CachedChunk? dropped = _chunkCache.remove(oldest);
      if (dropped != null) _chunkCacheBytes -= dropped.bytes;
    }
    if (_chunkCacheBytes < 0) _chunkCacheBytes = 0;
  }

  /// 把整份行表按 [linesChunkPages] 页一块写成独立文件，返回**成功写入的块数**
  ///
  /// ⚠️ **逐块 try**：单块写失败只跳过该块 —— 读取侧遇到缺块等价于"这些页没抽出来"
  /// （与 `isPageEmpty` 的语义一致），不影响其它块与主缓存。
  static int writeLineChunks(
    String dirPath,
    String documentId,
    Map<int, List<PdfLineBox>>? lines,
  ) {
    if (lines == null || lines.isEmpty) return 0;
    final Map<int, List<int>> byChunk = <int, List<int>>{};
    for (final int page in lines.keys) {
      byChunk.putIfAbsent(page ~/ linesChunkPages, () => <int>[]).add(page);
    }
    var written = 0;
    for (final MapEntry<int, List<int>> entry in byChunk.entries) {
      try {
        final List<int> pages = entry.value..sort();
        final Map<int, List<PdfLineBox>> chunkLines = <int, List<PdfLineBox>>{
          for (final int page in pages) page: lines[page]!,
        };
        final _Writer writer = _Writer();
        // ⚠️ 头里带**载荷长度**：读取侧据此判"文件被截断/改坏"
        //（`_Reader` 越界不一定抛，只靠 try 抓不住截断的块）
        final _Writer payload = _Writer();
        _writeLines(payload, chunkLines);
        final Uint8List payloadBytes = payload.takeBytes();
        writer.uint(_chunkMagic);
        writer.uint(_chunkVersion);
        writer.uint(entry.key);
        writer.uint(pages.first);
        writer.uint(pages.last);
        writer.uint(payloadBytes.length);
        for (final int b in payloadBytes) {
          writer.byte(b); // 原样追加载荷（_Writer 没有批量写字节的 API）
        }
        File(
          '$dirPath${Platform.pathSeparator}'
          '${linesChunkFileNameFor(documentId, entry.key)}',
        ).writeAsBytesSync(writer.takeBytes(), flush: false);
        written++;
      } catch (_) {
        // 单块失败不拖累其它块（缺块 = 那几页没行表）
      }
    }
    return written;
  }

  /// 读一块行表；文件不在 / 头不符 / 内容损坏 → **返回 null 不抛**
  ///
  /// 语义与"这页没抽出来"一致，调用方（阅读页）据此走重抽或留白。
  static Map<int, List<PdfLineBox>>? readLineChunk(String path) {
    try {
      final File file = File(path);
      if (!file.existsSync()) return null;
      final Uint8List data = file.readAsBytesSync();
      final _Reader reader = _Reader(data);
      if (reader.uint() != _chunkMagic) return null;
      if (reader.uint() != _chunkVersion) return null;
      reader.uint(); // 块号（完整性校验用）
      reader.uint(); // startPage
      reader.uint(); // endPage
      final int payloadLength = reader.uint();
      // ⚠️ `uint()` 是**变长编码**，不能按"固定头长 + 载荷长"去比字节数
      // （踩过：按 6×4 算，头实际只有 6~12 字节，正常文件也被判成坏块）。
      // 截断由 `_Reader` 自己的越界检查兜住（抛 FormatException → 被 catch → null）。
      if (payloadLength <= 0) return null;
      return _readLines(reader);
    } catch (_) {
      return null;
    }
  }

  /// 读缓存；不存在 / 版本不符 / 指纹不符 / 校验和不符一律返回 null（调用方回退到真解析）
  static ParsedSnapshot? read(String cachePath, String identity) {
    RandomAccessFile? handle;
    try {
      final file = File(cachePath);
      if (!file.existsSync()) return null;
      final length = file.lengthSync();
      if (length < headerBytes) return null;
      handle = file.openSync();
      final header = handle.readSync(headerBytes);
      if (header.length < headerBytes) return null;
      for (var i = 0; i < _magic.length; i++) {
        if (header[i] != _magic[i]) return null;
      }
      final view = ByteData.sublistView(header);
      final version = view.getUint16(_versionOffset, Endian.little);
      if (version != formatVersion) return null;
      final payloadLength = view.getUint32(_lengthOffset, Endian.little);
      if (payloadLength <= 0 || headerBytes + payloadLength > length) {
        return null;
      }

      // 分块读：大缓存一次性 assign 容易造成内存尖峰
      final payload = Uint8List(payloadLength);
      var offset = 0;
      while (offset < payloadLength) {
        final chunk = handle.readSync(payloadLength - offset);
        if (chunk.isEmpty) return null; // 文件被截断
        payload.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      if (_crc32(payload) != view.getUint32(_crcOffset, Endian.little)) {
        return null;
      }

      final reader = _Reader(payload);
      final storedIdentity = reader.string();
      if (storedIdentity != identity) return null;
      return _decodePayload(reader);
    } catch (_) {
      return null;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {
        // 关闭失败无所谓：缓存只是加速层
      }
    }
  }

  /// 写缓存（先写临时文件再改名，避免半截文件被当成有效缓存）；失败静默忽略
  ///
  /// [onError] 只在诊断 / 测试里传：缓存写不进去不该影响解析，
  /// 但排查「为什么没缓存」时需要能看到真实原因。
  static void write(
    String cachePath,
    String identity,
    ParsedSnapshot snapshot, {
    void Function(Object error)? onError,
  }) {
    RandomAccessFile? handle;
    try {
      final file = File(cachePath);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);

      final writer = _Writer();
      writer.string(identity);
      _encodePayload(writer, snapshot);
      final payload = writer.takeBytes();
      if (payload.length > maxCacheBytes) return;

      final header = Uint8List(headerBytes);
      for (var i = 0; i < _magic.length; i++) {
        header[i] = _magic[i];
      }
      final view = ByteData.sublistView(header);
      view.setUint16(_versionOffset, formatVersion, Endian.little);
      view.setUint32(_lengthOffset, payload.length, Endian.little);
      view.setUint32(_crcOffset, _crc32(payload), Endian.little);

      final temp = File('$cachePath.tmp');
      handle = temp.openSync(mode: FileMode.write);
      handle.writeFromSync(header);
      handle.writeFromSync(payload);
      handle.flushSync();
      handle.closeSync();
      handle = null;
      // 目标已存在时 rename 会覆盖（Android / Linux 上是原子替换）
      temp.renameSync(cachePath);
    } catch (error) {
      // 缓存写失败不能影响解析结果
      onError?.call(error);
      try {
        handle?.closeSync();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 删掉某份文档的缓存（删除文档时一并调用）
  static void remove(String cachePath) {
    try {
      final file = File(cachePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 忽略
    }
  }

  // ---------------- 载荷编解码 ----------------

  static void _encodePayload(_Writer writer, ParsedSnapshot snapshot) {
    writer.byte(snapshot.hasTextLayer ? 1 : 0);
    writer.nullableString(snapshot.encoding);
    writer.uint(snapshot.pageCount);
    writer.uint(snapshot.textCharCount);
    writer.uint(snapshot.fileSize);
    writer.uint(snapshot.textRevision);
    final pageSize = snapshot.pageSize;
    writer.float64(pageSize?.width ?? 0);
    writer.float64(pageSize?.height ?? 0);

    final document = snapshot.document;
    writer.byte(document.chapterIsPage ? 1 : 0);
    writer.uint(document.chapters.length);
    for (final chapter in document.chapters) {
      writer.string(chapter.title);
      writer.uint(chapter.paragraphs.length);
      for (final paragraph in chapter.paragraphs) {
        final sentences = paragraph.sentences;
        writer.uint(sentences.length);
        for (final sentence in sentences) {
          writer.string(sentence.text);
        }
      }
    }

    writer.uint(document.outline.length);
    for (final entry in document.outline) {
      writer.string(entry.title);
      writer.uint(entry.chapter);
      writer.uint(entry.paragraph);
      writer.uint(entry.depth);
    }

    // v1.21.33 / L2a：行表编解码抽成 [_writeLines] / [_readLines]，
    // 主缓存与「分块行表文件」（`.ttsl`）共用同一套字节格式 —— 一处改、两处一致。
    // ⚠️ 抽出来**不改字节布局**：老缓存的往返行为由 document_cache_test 守住。
    //
    // v1.21.35 / L2b-2：**主缓存不再写整份行表**。行表只活在 `<docId>.lines.<n>.ttsl`
    // 分块文件里（生产者是 `document_service.writeCache` 里那句 `writeLineChunks`，
    // 它必须保留）。这里仍然写一个 `uint(0)`（= "这份文档没有行表"）
    // **把字段位置占住** → 字节布局与 v3 一致，读侧 `pdfLines` 恒为 null，
    // 消费方一律走"按块读"（`DocumentCache.readLineChunkByName`）。
    _writeLines(writer, null);

    // v1.21.34 / L2b-1：**载荷尾部追加**行表分块索引（追加 → 已有字段偏移不变）。
    // L2b-2 起它是读侧的**唯一地图**：没有它就不知道有哪些块、每块覆盖哪些页。
    final List<LinesChunkRef> chunks =
        snapshot.linesChunks ?? _chunksOf(snapshot.pdfLines);
    writer.uint(chunks.length);
    for (final LinesChunkRef ref in chunks) {
      writer.uint(ref.chunk);
      writer.uint(ref.startPage);
      writer.uint(ref.endPage);
    }
  }

  /// 从行表推算分块索引（与 [writeLineChunks] 的分块口径必须一致）
  ///
  /// v1.21.35 / L2b-2 起对 `reader_page` 公开：解析**没命中缓存**时（刚真解析完），
  /// 阅读页手上只有整份行表、没有索引，靠这个方法算出"该去读哪些块"。
  /// ⚠️ 真的**落盘**索引是 [_encodePayload] 写的，读取地图以那份为准。
  static List<LinesChunkRef> chunksOf(Map<int, List<PdfLineBox>>? lines) =>
      _chunksOf(lines);

  /// 从行表推算分块索引（与 [writeLineChunks] 的分块口径必须一致）
  static List<LinesChunkRef> _chunksOf(Map<int, List<PdfLineBox>>? lines) {
    if (lines == null || lines.isEmpty) return const <LinesChunkRef>[];
    final Map<int, List<int>> byChunk = <int, List<int>>{};
    for (final int page in lines.keys) {
      byChunk.putIfAbsent(page ~/ linesChunkPages, () => <int>[]).add(page);
    }
    final List<int> chunkIds = byChunk.keys.toList()..sort();
    return <LinesChunkRef>[
      for (final int chunk in chunkIds)
        LinesChunkRef(
          chunk: chunk,
          startPage: (byChunk[chunk]!.reduce(math.min)),
          endPage: (byChunk[chunk]!.reduce(math.max)),
        ),
    ];
  }

  /// 行表写入：`uint(页数)`；每页 `uint(页码) uint(行数)`；每行 `string(文本) float64×4(包围盒)`
  ///
  /// null / 空表写一个 `uint(0)`（读回得到 null，语义 = 这份文档没有行表）。
  static void _writeLines(_Writer writer, Map<int, List<PdfLineBox>>? lines) {
    if (lines == null || lines.isEmpty) {
      writer.uint(0);
      return;
    }
    writer.uint(lines.length);
    for (final page in lines.entries) {
      writer.uint(page.key);
      writer.uint(page.value.length);
      for (final box in page.value) {
        writer.string(box.text);
        writer.float64(box.bounds.left);
        writer.float64(box.bounds.top);
        writer.float64(box.bounds.right);
        writer.float64(box.bounds.bottom);
      }
    }
  }

  /// 行表读回：页数为 0 → 返回 null（调用方按"没有行表"处理）
  static Map<int, List<PdfLineBox>>? _readLines(_Reader reader) {
    final pageKeys = reader.uint();
    if (pageKeys <= 0) return null;
    final lineMap = <int, List<PdfLineBox>>{};
    for (var i = 0; i < pageKeys; i++) {
      final page = reader.uint();
      final count = reader.uint();
      final boxes = <PdfLineBox>[];
      for (var j = 0; j < count; j++) {
        boxes.add(
          PdfLineBox(
            text: reader.string(),
            bounds: Rect.fromLTRB(
              reader.float64(),
              reader.float64(),
              reader.float64(),
              reader.float64(),
            ),
          ),
        );
      }
      lineMap[page] = boxes;
    }
    return lineMap;
  }

  static ParsedSnapshot _decodePayload(_Reader reader) {
    final hasTextLayer = reader.byte() == 1;
    final encoding = reader.nullableString();
    final pageCount = reader.uint();
    final textCharCount = reader.uint();
    final fileSize = reader.uint();
    final textRevision = reader.uint();
    final pageWidth = reader.float64();
    final pageHeight = reader.float64();
    final pageSize =
        pageWidth > 0 && pageHeight > 0 ? Size(pageWidth, pageHeight) : null;

    final chapterIsPage = reader.byte() == 1;
    final chapterCount = reader.uint();
    final chapters = <Chapter>[];
    for (var c = 0; c < chapterCount; c++) {
      final title = reader.string();
      final paragraphCount = reader.uint();
      final paragraphs = <Paragraph>[];
      for (var p = 0; p < paragraphCount; p++) {
        final sentenceCount = reader.uint();
        final sentences = <Sentence>[];
        for (var s = 0; s < sentenceCount; s++) {
          sentences.add(Sentence(reader.string()));
        }
        paragraphs.add(Paragraph(sentences: sentences));
      }
      chapters.add(Chapter(title: title, paragraphs: paragraphs));
    }

    final outlineCount = reader.uint();
    final outline = <DocumentOutlineEntry>[];
    for (var i = 0; i < outlineCount; i++) {
      outline.add(
        DocumentOutlineEntry(
          title: reader.string(),
          chapter: reader.uint(),
          paragraph: reader.uint(),
          depth: reader.uint(),
        ),
      );
    }

    // v1.21.33 / L2a：与 [_writeLines] 同一套字节格式（抽出来供分块文件复用）
    final lineMap = _readLines(reader);

    // v1.21.34 / L2b-1：读回载荷尾部的分块索引（v3 一定写了它）。
    // ⚠️ 读侧目前**只填字段、不消费** —— L2b-2 才用它去读块文件。
    final int chunkCount = reader.uint();
    final List<LinesChunkRef> chunks = <LinesChunkRef>[];
    for (var i = 0; i < chunkCount; i++) {
      chunks.add(
        LinesChunkRef(
          chunk: reader.uint(),
          startPage: reader.uint(),
          endPage: reader.uint(),
        ),
      );
    }

    return ParsedSnapshot(
      document: StructuredDocument(
        chapters: chapters,
        chapterIsPage: chapterIsPage,
        outline: outline,
      ),
      hasTextLayer: hasTextLayer,
      pageCount: pageCount,
      textCharCount: textCharCount,
      fileSize: fileSize,
      encoding: encoding,
      pdfLines: lineMap,
      textRevision: textRevision,
      pageSize: pageSize,
      linesChunks: chunks,
    );
  }

  /// CRC-32（IEEE）：缓存文件被写坏 / 截断时能立刻发现，而不是解出半本书
  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      crc = _crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static final Uint32List _crcTable = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var value = i;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
      }
      table[i] = value;
    }
    return table;
  }
}

/// 一份可缓存的解析快照
///
/// 与 `DocumentService` 的 `ParseResult` 字段一一对应，但不含封面路径
/// （封面是单独的文件，路径存在文档库里，不进缓存）。
class ParsedSnapshot {
  const ParsedSnapshot({
    required this.document,
    required this.hasTextLayer,
    required this.pageCount,
    required this.textCharCount,
    this.fileSize = 0,
    this.encoding,
    this.pdfLines,
    this.textRevision = 0,
    this.pageSize,
    this.linesChunks,
  });

  final StructuredDocument document;
  final bool hasTextLayer;
  final int pageCount;
  final int textCharCount;
  final int fileSize;
  final String? encoding;
  final Map<int, List<PdfLineBox>>? pdfLines;

  /// PDF 页面尺寸（点为单位）；非 PDF 或没抽到行信息时为空
  final Size? pageSize;

  /// 生成这份结果的解析器版本（解析规则改动时递增，用于让旧缓存失效）
  final int textRevision;

  /// 行表分块索引（v1.21.34 / L2b-1 引入，v1.21.35 / L2b-2 起是**读取地图**）
  ///
  /// L2b-2 起主缓存**不再写整份行表**（`pdfLines` 读回恒为 null），
  /// 阅读页靠这份索引去读 `<docId>.lines.<n>.ttsl`。
  /// 写侧由 `document_service.writeCache` 从解析结果填进来；读侧由 [_decodePayload] 读回。
  final List<LinesChunkRef>? linesChunks;
}

/// 一个行表分块的索引项：块号 + 覆盖的页号区间（闭区间）
class LinesChunkRef {
  const LinesChunkRef({
    required this.chunk,
    required this.startPage,
    required this.endPage,
  });

  final int chunk;
  final int startPage;
  final int endPage;

  @override
  String toString() => 'chunk$chunk[$startPage..$endPage]';
}

/// 块读缓存里的一项：解码后的行表 + 它的估算字节数（淘汰按这个数算）
class _CachedChunk {
  const _CachedChunk(this.bytes, this.lines);

  final int bytes;
  final Map<int, List<PdfLineBox>> lines;
}

/// 二进制写入器：全部小端，字符串按 UTF-8 前缀长度
class _Writer {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void byte(int value) => _bytes.addByte(value & 0xFF);

  /// 变长无符号整数（每字节 7 位，高位表示还有后续）
  void uint(int value) {
    var rest = value < 0 ? 0 : value;
    while (rest >= 0x80) {
      _bytes.addByte((rest & 0x7F) | 0x80);
      rest >>= 7;
    }
    _bytes.addByte(rest);
  }

  /// 64 位浮点（PDF 行外框用）
  ///
  /// 注意不能起名 `double`：方法名会遮盖 `double` 这个类型名，
  /// 上面那行的参数类型就解析不了了。
  void float64(double value) {
    final data = ByteData(8);
    data.setFloat64(0, value.isFinite ? value : 0, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void string(String value) {
    final data = utf8.encode(value);
    uint(data.length);
    _bytes.add(data);
  }

  /// null 与空串要区分开（编码名可能是空）
  void nullableString(String? value) {
    if (value == null) {
      uint(0);
      return;
    }
    final data = utf8.encode(value);
    uint(data.length + 1);
    _bytes.add(data);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// 二进制读取器（与 [_Writer] 严格对称）
class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  int _offset = 0;

  int byte() {
    if (_offset >= _data.length) throw const FormatException('缓存数据不完整');
    return _data[_offset++];
  }

  int uint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final value = byte();
      result |= (value & 0x7F) << shift;
      if (value < 0x80) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('整数长度异常');
    }
  }

  double float64() {
    if (_offset + 8 > _data.length) throw const FormatException('缓存数据不完整');
    final value = ByteData.sublistView(_data, _offset, _offset + 8)
        .getFloat64(0, Endian.little);
    _offset += 8;
    return value;
  }

  String string() {
    final length = uint();
    if (_offset + length > _data.length) throw const FormatException('字符串越界');
    final value = utf8.decode(_data.sublist(_offset, _offset + length));
    _offset += length;
    return value;
  }

  String? nullableString() {
    final length = uint();
    if (length == 0) return null;
    final actual = length - 1;
    if (_offset + actual > _data.length) throw const FormatException('字符串越界');
    final value = utf8.decode(_data.sublist(_offset, _offset + actual));
    _offset += actual;
    return value;
  }
}
