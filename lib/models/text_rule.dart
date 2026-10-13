/// 一条「朗读文本预处理」规则（对应 T2S 的 Text Process Rules）
///
/// 朗读前按列表顺序应用：把匹配到的内容替换掉（[replacement] 为空即删除）。
/// 典型用途是解决「读出来不对」的问题：符号读不出来（△、→）、
/// 参考文献编号被念出来（[1]）、网址被逐字符念出来。
class TextRule {
  const TextRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
    this.isRegex = true,
    this.builtin = false,
  });

  /// 从持久化数据还原；缺字段按默认值补齐，坏数据不抛异常
  factory TextRule.fromJson(Map<String, dynamic> json) => TextRule(
    id: _string(json['id']),
    name: _string(json['name']),
    pattern: _string(json['pattern']),
    replacement: _string(json['replacement']),
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    isRegex: json['isRegex'] is bool ? json['isRegex'] as bool : true,
    builtin: json['builtin'] == true,
  );

  static String _string(Object? value) => value is String ? value : '';

  /// 稳定标识（内置规则用它做「恢复默认」的比对）
  final String id;

  /// 显示名称
  final String name;

  /// 查找内容：正则表达式或字面量
  final String pattern;

  /// 替换为：空字符串表示删除匹配到的内容
  final String replacement;

  /// 是否启用（停用后不参与预处理，便于临时对比效果）
  final bool enabled;

  /// true 时 [pattern] 按正则解释，false 按纯文本字面量
  final bool isRegex;

  /// 是否为内置预设（可停用 / 删除，「恢复默认」能找回来）
  final bool builtin;

  /// 正则编译缓存的键
  String get cacheKey => '${isRegex ? 'r' : 'p'}|$pattern';

  /// 列表里的一行摘要：`\[[^\]]*\] → （删除）`
  String get summary => pattern.isEmpty
      ? '（未填写查找内容）'
      : '$pattern → ${replacement.isEmpty ? '（删除）' : replacement}';

  TextRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    bool? enabled,
    bool? isRegex,
    bool? builtin,
  }) => TextRule(
    id: id ?? this.id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    enabled: enabled ?? this.enabled,
    isRegex: isRegex ?? this.isRegex,
    builtin: builtin ?? this.builtin,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'enabled': enabled,
    'isRegex': isRegex,
    'builtin': builtin,
  };

  @override
  String toString() => 'TextRule($id, $name, $summary, enabled=$enabled)';

  /// 内置预设：首次运行播种，也可以随时「恢复默认」找回
  ///
  /// 前两条对应 T2S 帮助文本里的例子（Replace "△" to "triangle" /
  /// Remove square brackets），第三条对应它的「不朗读维基百科参考文献」开关。
  static const List<TextRule> defaults = <TextRule>[
    TextRule(
      id: 'builtin.bracket',
      name: '去掉方括号内容',
      pattern: r'\[[^\]]*\]',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.wiki-ref',
      name: '不朗读维基参考文献 [1][2]',
      pattern: r'\[\d+\]',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.triangle',
      name: '把 △ 读成「三角形」',
      pattern: r'△',
      replacement: '三角形',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.arrow',
      name: '把箭头读成「到」',
      pattern: r'[→➔➜]',
      replacement: '到',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.url',
      name: '不朗读网址',
      pattern: r'https?://[^\s，。；）)】]+',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.markdown',
      name: '去掉 Markdown 标记（* _ ` ~）',
      pattern: r'[*_`~]{1,3}',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.html-space',
      name: '还原网页空格实体',
      pattern: r'&(nbsp|#160|ensp|emsp);',
      replacement: ' ',
      builtin: true,
    ),
    TextRule(
      id: 'builtin.blank',
      name: '连续空格压成一个',
      pattern: r'[ \t　]{2,}',
      replacement: ' ',
      builtin: true,
    ),
  ];
}
