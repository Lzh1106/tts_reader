import 'dart:io';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/structured_document.dart';

/// 从文件路径读 PDF 目录（书签）。
///
/// 给 `features/pdf_reading`（pdfrx 那套）复用：那边渲染用 pdfrx，
/// 但**书签解析继续用 Syncfusion** —— 它读 `/Outlines` 已经验证过
/// （HANDOFF §9.33 还记着它 `bookmarks.add` 命名参数是摆设的坑），
/// 没必要为目录再写一套。
///
/// 任何异常都按「没有目录」处理：目录只是辅助功能，不能影响朗读。
Future<List<DocumentOutlineEntry>> readPdfOutline(String filePath) async {
  if (!File(filePath).existsSync()) return const <DocumentOutlineEntry>[];
  PdfDocument? document;
  try {
    final bytes = await File(filePath).readAsBytes();
    document = PdfDocument(inputBytes: bytes);
    return PdfOutlineReader.read(document);
  } catch (_) {
    return const <DocumentOutlineEntry>[];
  } finally {
    document?.dispose();
  }
}

/// 从 PDF 的书签（文档大纲 / outline）抽出目录
///
/// PDF 的目录就藏在书签树里（`/Outlines`），Syncfusion 把它暴露成
/// `PdfDocument.bookmarks`：每个书签有标题、跳转目标（目标页）与子书签。
/// 没有书签的 PDF（扫描件、自制文件）抽出来是空列表，调用方退回「第 N 页」。
///
/// 注意与「章节」的关系：本工程里 PDF 的**章号 == 页号**（原版式翻页、按页朗读都靠它），
/// 所以目录条目只记录「跳到第几页」，不会改变章节结构。
class PdfOutlineReader {
  PdfOutlineReader._();

  /// 最多读多少条（防止畸形 PDF 的环状书签把内存吃满）
  static const int maxEntries = 5000;

  /// 最多下钻多少层
  static const int maxDepth = 8;

  /// 标题最长保留多少字
  static const int maxTitleLength = 120;

  /// 读目录；任何异常都按「没有目录」处理，不影响朗读
  static List<DocumentOutlineEntry> read(PdfDocument document) {
    final entries = <DocumentOutlineEntry>[];
    try {
      final bookmarks = document.bookmarks;
      _walk(bookmarks, document, 0, entries);
    } catch (_) {
      // 书签结构损坏：当作没有目录
    }
    return entries;
  }

  /// 目录标题 → 页号（每页只取第一次出现的那条，给章节起名用）
  static Map<int, String> titlesByPage(List<DocumentOutlineEntry> entries) {
    final map = <int, String>{};
    for (final entry in entries) {
      // 顶层标题更可能是章节名；同一页已有标题时不覆盖
      final existing = map[entry.chapter];
      if (existing == null) {
        map[entry.chapter] = entry.title;
      }
    }
    return map;
  }

  static void _walk(
    PdfBookmarkBase node,
    PdfDocument document,
    int depth,
    List<DocumentOutlineEntry> out,
  ) {
    if (depth > maxDepth || out.length >= maxEntries) return;
    int count;
    try {
      count = node.count;
    } catch (_) {
      return;
    }
    for (var i = 0; i < count; i++) {
      if (out.length >= maxEntries) return;
      PdfBookmark bookmark;
      try {
        bookmark = node[i];
      } catch (_) {
        continue;
      }

      final title = cleanTitle(_titleOf(bookmark));
      final page = _pageOf(bookmark, document);
      if (title.isNotEmpty && page != null && page >= 0) {
        out.add(DocumentOutlineEntry(title: title, chapter: page, depth: depth));
      }
      // 即使这一条没有标题或目标，子书签仍可能有
      _walk(bookmark, document, depth + 1, out);
    }
  }

  static String _titleOf(PdfBookmark bookmark) {
    try {
      return bookmark.title;
    } catch (_) {
      return '';
    }
  }

  /// 书签目标页；命名目标 / 远程目标取不到时返回 null
  static int? _pageOf(PdfBookmark bookmark, PdfDocument document) {
    try {
      final destination = bookmark.destination;
      if (destination == null) return null;
      final page = destination.page;
      final index = document.pages.indexOf(page);
      return index < 0 ? null : index;
    } catch (_) {
      return null;
    }
  }

  /// 标题清洗：去掉换行与控制字符、压缩空白、截断过长标题
  static String cleanTitle(String raw) {
    var text = raw
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // 有些 PDF 的标题带前导编号点或引号，保留原样即可，这里只处理长度
    if (text.length > maxTitleLength) text = '${text.substring(0, maxTitleLength)}…';
    return text;
  }
}
