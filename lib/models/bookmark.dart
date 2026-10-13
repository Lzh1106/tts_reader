/// 文档书签（对应 T2S 的 bookmark 模块）
///
/// 记录「哪本书的哪个位置」以及当时的正文片段，便于在列表里一眼认出来。
/// 位置用朗读游标 (章, 段, 句) 表示，与阅读进度、目录跳转共用同一套坐标。
class Bookmark {
  const Bookmark({
    required this.id,
    required this.documentId,
    required this.documentTitle,
    required this.chapter,
    required this.paragraph,
    required this.sentence,
    required this.preview,
    required this.createdAt,
  });

  /// 从持久化数据还原；缺字段按占位处理，坏数据不抛异常
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: _string(json['id']),
    documentId: _string(json['documentId']),
    documentTitle: _string(json['documentTitle']),
    chapter: _int(json['chapter']),
    paragraph: _int(json['paragraph']),
    sentence: _int(json['sentence']),
    preview: _string(json['preview']),
    createdAt: DateTime.tryParse(_string(json['createdAt'])) ?? DateTime(2024),
  );

  static String _string(Object? value) => value is String ? value : '';

  static int _int(Object? value) =>
      value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? 0 : 0);

  /// 书签预览长度上限
  static const int previewLimit = 80;

  final String id;

  /// 所属文档 id（与 Document.id 对应）
  final String documentId;

  /// 所属文档标题（文档被移除后仍能显示是给哪本书做的书签）
  final String documentTitle;

  final int chapter;
  final int paragraph;
  final int sentence;

  /// 书签处的正文片段
  final String preview;

  final DateTime createdAt;

  /// 朗读游标
  (int, int, int) get cursor => (chapter, paragraph, sentence);

  /// 位置标签；PDF（一章即一页）显示页码，其余显示章 / 段
  String label({bool chapterIsPage = false}) => chapterIsPage
      ? '第 ${chapter + 1} 页'
      : '第 ${chapter + 1} 章 · 第 ${paragraph + 1} 段';

  /// 是否与另一个书签指向同一位置
  bool sameSpot(Bookmark other) =>
      documentId == other.documentId &&
      chapter == other.chapter &&
      paragraph == other.paragraph &&
      sentence == other.sentence;

  /// 是否与给定游标指向同一位置
  bool matches((int, int, int) spot) =>
      chapter == spot.$1 && paragraph == spot.$2 && sentence == spot.$3;

  /// 生成位置片段（超过上限截断），供新建书签时调用
  static String makePreview(String text) {
    final trimmed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.length > previewLimit
        ? '${trimmed.substring(0, previewLimit)}…'
        : trimmed;
  }

  Bookmark copyWith({String? preview, DateTime? createdAt}) => Bookmark(
    id: id,
    documentId: documentId,
    documentTitle: documentTitle,
    chapter: chapter,
    paragraph: paragraph,
    sentence: sentence,
    preview: preview ?? this.preview,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'documentId': documentId,
    'documentTitle': documentTitle,
    'chapter': chapter,
    'paragraph': paragraph,
    'sentence': sentence,
    'preview': preview,
    'createdAt': createdAt.toIso8601String(),
  };

  @override
  String toString() => 'Bookmark($id, $documentTitle, $chapter/$paragraph/$sentence)';
}
