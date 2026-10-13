/// 文档类型：PDF / EPUB / TXT
enum DocumentType {
  pdf('pdf', 'PDF'),
  epub('epub', 'EPUB'),
  txt('txt', 'TXT');

  const DocumentType(this.ext, this.label);

  /// 文件扩展名（小写，不带点）
  final String ext;

  /// 界面展示名
  final String label;

  /// 由扩展名或文件名解析类型，未知一律按 txt 处理
  static DocumentType fromExtension(String value) {
    var v = value.toLowerCase().trim();
    final dot = v.lastIndexOf('.');
    if (dot >= 0 && dot < v.length - 1) v = v.substring(dot + 1);
    return switch (v) {
      'pdf' => DocumentType.pdf,
      'epub' => DocumentType.epub,
      _ => DocumentType.txt,
    };
  }

  /// 由 JSON 中的字符串还原（容错）
  static DocumentType fromName(Object? name) => switch (name) {
    'pdf' => DocumentType.pdf,
    'epub' => DocumentType.epub,
    _ => DocumentType.txt,
  };

  /// 这个文件能不能朗读（PDF / EPUB / TXT）
  ///
  /// 不能拿 [fromExtension] 代替：它把未知扩展名一律当 txt，
  /// 那样 .mobi / .azw3 之类的文件也会被当成文本文档导进文档库。
  static bool isReadable(String pathOrName) {
    final dot = pathOrName.lastIndexOf('.');
    if (dot < 0 || dot == pathOrName.length - 1) return false;
    final ext = pathOrName.substring(dot + 1).toLowerCase();
    return ext == 'pdf' || ext == 'epub' || ext == 'txt';
  }
}

/// 文档库条目：只保存元数据，正文在打开时按需解析
class Document {
  const Document({
    required this.id,
    required this.title,
    required this.path,
    required this.type,
    required this.importedAt,
    this.progress = 0,
    this.coverPath,
    this.hasTextLayer,
    this.lastReadAt,
  });

  final String id;
  final String title;

  /// 本地文件绝对路径
  final String path;
  final DocumentType type;

  /// 阅读进度 0.0 ~ 1.0
  final double progress;

  /// 导入时间
  final DateTime importedAt;

  /// 封面图本地路径（EPUB 抽取，其它类型为 null 时用占位封面）
  final String? coverPath;

  /// 是否检测到可朗读的文本层（null = 尚未解析；PDF 为 false 表示扫描件）
  final bool? hasTextLayer;

  /// 最后一次阅读时间（null = 从未打开过），供「最近阅读」排序使用
  final DateTime? lastReadAt;

  /// 排序用的时间：读过就用最近阅读时间，没读过就用导入时间
  DateTime get activityAt => lastReadAt ?? importedAt;

  Document copyWith({
    String? title,
    String? path,
    DocumentType? type,
    double? progress,
    String? coverPath,
    bool? hasTextLayer,
    DateTime? lastReadAt,
  }) => Document(
    id: id,
    title: title ?? this.title,
    path: path ?? this.path,
    type: type ?? this.type,
    progress: progress ?? this.progress,
    importedAt: importedAt,
    coverPath: coverPath ?? this.coverPath,
    hasTextLayer: hasTextLayer ?? this.hasTextLayer,
    lastReadAt: lastReadAt ?? this.lastReadAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'path': path,
    'type': type.name,
    'progress': progress,
    'importedAt': importedAt.toIso8601String(),
    'coverPath': coverPath,
    'hasTextLayer': hasTextLayer,
    'lastReadAt': lastReadAt?.toIso8601String(),
  };

  factory Document.fromJson(Map<String, dynamic> json) {
    final rawProgress = (json['progress'] as num?)?.toDouble() ?? 0;
    return Document(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名文档',
      path: json['path'] as String? ?? '',
      type: DocumentType.fromName(json['type']),
      progress: rawProgress < 0 ? 0 : (rawProgress > 1 ? 1 : rawProgress),
      importedAt: DateTime.tryParse(json['importedAt'] as String? ?? '') ?? DateTime.now(),
      coverPath: json['coverPath'] as String?,
      hasTextLayer: json['hasTextLayer'] as bool?,
      lastReadAt: DateTime.tryParse(json['lastReadAt'] as String? ?? ''),
    );
  }

  @override
  String toString() => 'Document($id, $title, ${type.name})';
}
