import 'dart:async';

/// 把一段文本合成到音频文件的函数（真实实现走系统 TTS，测试注入假实现）
typedef SynthToFile = Future<bool> Function(String text, String fileName);

/// 一个待合成的片段（= 一个音频文件）
class AudioPart {
  const AudioPart({
    required this.index,
    required this.fileName,
    required this.text,
    required this.chapterIndex,
    required this.chapterTitle,
  });

  /// 全书序号（从 1 开始）
  final int index;

  /// 输出文件名（含扩展名）
  final String fileName;

  /// 要合成的文本
  final String text;

  /// 所属章（从 0 开始）
  final int chapterIndex;

  final String chapterTitle;

  @override
  String toString() => 'AudioPart($index, $fileName, ${text.length} 字)';
}

/// 一次导出的分片计划
class AudioExportPlan {
  const AudioExportPlan({required this.baseName, required this.parts});

  /// 文件名前缀（已做非法字符处理）
  final String baseName;

  final List<AudioPart> parts;

  int get totalChars => parts.fold(0, (sum, part) => sum + part.text.length);

  bool get isEmpty => parts.isEmpty;

  /// 播放列表内容（m3u，按顺序列出文件名）
  ///
  /// 导出的音频是一段一个文件，播放器默认按文件名排序不一定对，
  /// 附带一份 m3u 可以直接按顺序连着听。
  String toPlaylist() {
    final buffer = StringBuffer('#EXTM3U\n');
    for (final part in parts) {
      buffer.writeln('#EXTINF:-1,${part.chapterTitle} · ${part.index}');
      buffer.writeln(part.fileName);
    }
    return buffer.toString();
  }
}

/// 导出进度
class AudioExportProgress {
  const AudioExportProgress({
    required this.done,
    required this.total,
    required this.failed,
  });

  final int done;
  final int total;
  final int failed;

  double get fraction => total <= 0 ? 0 : done / total;
}

/// 导出结果
class AudioExportReport {
  const AudioExportReport({
    required this.files,
    required this.failed,
    required this.cancelled,
  });

  /// 成功生成的文件名（按顺序）
  final List<String> files;

  /// 失败的片段（文件名）
  final List<String> failed;

  /// 是否被用户中途取消
  final bool cancelled;

  bool get hasFailure => failed.isNotEmpty;
}

/// 朗读音频导出（对应 T2S 的「导出为音频文件」/ LAME MP3 插件）
///
/// 与插件解耦：真正合成的一步由 [SynthToFile] 注入，因此分片、进度、取消、
/// 失败继续这些逻辑都能在没有原生 TTS 的环境里跑测试。
class AudioExporter {
  /// 单片文本长度上限
  ///
  /// 系统 TTS 单次合成有输入上限（与朗读同一条限制），超长会被截断，
  /// 所以按句子切片，保证不丢字。
  static const int maxPartLength = 240;

  /// 文件名里不能出现的字符（Windows / Android / iOS 通吃的一套）
  static final RegExp _illegal = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

  /// 文件名前缀最大长度（留出序号与扩展名）
  static const int maxBaseLength = 40;

  /// 清洗文件名：去掉非法字符与首尾空白，过长时截断
  static String sanitize(String name) {
    var value = name.replaceAll(_illegal, '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    // Windows 上文件名不能以点结尾
    value = value.replaceAll(RegExp(r'[. ]+$'), '');
    if (value.length > maxBaseLength) value = value.substring(0, maxBaseLength);
    return value.isEmpty ? '朗读音频' : value;
  }

  /// 把一章文本按句子切成若干片段
  ///
  /// 单句就超过上限时硬切，宁可切开也不能整片丢弃。
  static List<String> splitText(String text, {int maxLength = maxPartLength}) {
    final limit = maxLength < 1 ? maxPartLength : maxLength;
    final parts = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final value = buffer.toString().trim();
      buffer.clear();
      if (value.isNotEmpty) parts.add(value);
    }

    // 按句末标点切，标点跟着前一句
    for (final match in RegExp(r'[^。！？!?\.\n；;]+[。！？!?\.；;]?').allMatches(text)) {
      var sentence = match.group(0) ?? '';
      if (sentence.trim().isEmpty) continue;
      while (sentence.length > limit) {
        flush();
        parts.add(sentence.substring(0, limit).trim());
        sentence = sentence.substring(limit);
      }
      if (buffer.length + sentence.length > limit) flush();
      buffer.write(sentence);
    }
    flush();
    return parts;
  }

  /// 生成分片计划：每章切成若干片段，全书连续编号
  static AudioExportPlan plan({
    required List<(String title, String text)> chapters,
    required String baseName,
    String extension = 'wav',
    int maxPartLength = maxPartLength,
  }) {
    final safeBase = sanitize(baseName);
    final ext = extension.startsWith('.') ? extension.substring(1) : extension;
    final parts = <AudioPart>[];
    var index = 0;
    for (var c = 0; c < chapters.length; c++) {
      final (title, text) = chapters[c];
      for (final chunk in splitText(text, maxLength: maxPartLength)) {
        index++;
        parts.add(
          AudioPart(
            index: index,
            fileName: '$safeBase-${index.toString().padLeft(3, '0')}.$ext',
            text: chunk,
            chapterIndex: c,
            chapterTitle: title,
          ),
        );
      }
    }
    return AudioExportPlan(baseName: safeBase, parts: parts);
  }

  /// 执行导出：逐片合成，单片刻失败不中断整次导出
  ///
  /// [isCancelled] 每片开始前检查一次，取消后就地收尾（已生成的文件保留）。
  static Future<AudioExportReport> run(
    AudioExportPlan plan, {
    required SynthToFile synth,
    void Function(AudioExportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final files = <String>[];
    final failed = <String>[];
    final total = plan.parts.length;
    var done = 0;

    for (final part in plan.parts) {
      if (isCancelled?.call() ?? false) {
        return AudioExportReport(files: files, failed: failed, cancelled: true);
      }
      var ok = false;
      try {
        ok = await synth(part.text, part.fileName);
      } catch (_) {
        ok = false;
      }
      if (ok) {
        files.add(part.fileName);
      } else {
        failed.add(part.fileName);
      }
      done++;
      onProgress?.call(AudioExportProgress(done: done, total: total, failed: failed.length));
    }
    return AudioExportReport(files: files, failed: failed, cancelled: false);
  }
}
