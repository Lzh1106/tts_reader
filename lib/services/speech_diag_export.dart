import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'crash_log.dart';
import 'speech_diagnostics.dart';
import 'storage_service.dart';

/// 朗读跳动检测的**导出层**：落盘 + 剪贴板 + 分享。
///
/// ## 落点（v1.21.28 重做，按用户设置二选一，见 [dir]）
///
/// - **系统可见**（默认）：`/storage/emulated/0/Android/data/<pkg>/files/speech_diag/`
///   —— 系统文件管理器可见（部分 ROM 需显示 `Android/data/`）、`adb shell ls` 直读、
///   卸载时随应用清理，且**在 `share_plus` 的 FileProvider 白名单里**（分享不会崩）；
/// - **应用私有**：`/data/user/0/<pkg>/files/speech_diag/`
///   —— 只能 `adb shell run-as <包名> cat` 取，文件管理器看不到。
///
/// ## 为什么不再用 `app_flutter/`（旧注释是错的，v1.21.28 更正）
///
/// 旧实现用 `getApplicationDocumentsDirectory()`（Android → `app_flutter/`），
/// 旧注释还写着"只有 `app_flutter/` 能 adb 读、`files/` 不行" —— **这句是错的**：
/// `adb shell run-as <包名>` 进去后 `files/` 与 `app_flutter/` 在同一层，都能读。
/// 真正的三个坑是：
///   · **分享闪退**：`app_flutter/` 不在 share_plus 的 FileProvider 白名单里
///     （白名单只有 `cache/`、`files/`、`external/` 三个根），分享时原生侧抛
///     `FileUriExposedException`；
///   · **路径"虚假"**：`/data/user/0/...` 对系统文件管理器不可见，用户找不到；
///   · **偶发导出失败**：某些 ROM 上 `getApplicationDocumentsDirectory()`
///     首次调用不稳定，`create(recursive: true)` 抛异常会让整次导出失败。
///
/// v1.21.13 / B-P2 的子目录约定（`speech_diag/`）保持不变 —— 诊断文件不跟
/// 用户导入的书籍、下载混在一起。
class SpeechDiagExport {
  SpeechDiagExport._();

  /// 与 `pubspec.yaml` 的 `version:` 保持一致。
  ///
  /// 为什么不引 `package_info_plus`：pubspec 里已注明它的 9.x 依赖会与本工程的
  /// AGP 8.3 / Kotlin 1.9 冲突（`wakelock_plus` 就是因此锁在 1.2.x）。
  /// 版本升级时**手工同步这一行**。
  static const String appVersion = '1.21.41+92';

  /// 与 `pubspec.yaml` 的 `+92` 对应。
  static const String buildNumber = '92';

  /// 导出文件名：`speech_diag_<时间戳>.log`
  static String stamp([DateTime? at]) {
    final DateTime t = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 组装元信息段。
  static Map<String, String> meta() => <String, String>{
        'app_version': appVersion,
        'build': buildNumber,
        'device': Platform.operatingSystemVersion,
        'android': Platform.operatingSystemVersion,
      };

  /// 按 schema 生成导出文本（不落盘，便于单测直接断言）。
  static String buildText({required bool includeAllEvents}) =>
      SpeechDiagnostics.instance
          .buildExportText(includeAllEvents: includeAllEvents, meta: meta());

  /// 诊断目录：`app_flutter/speech_diag/`（**子目录**，B-P2），不存在就建。
  ///
  /// `create(recursive: true)`：父目录（`app_flutter`）由系统保证存在，
  /// 但递归创建可以顺带兜住「目录被用户/清理工具删掉」的情况。
  static Future<Directory> dir() async {
    Directory? base;
    if (StorageService.instance.speechDiagToExternal) {
      try {
        // 应用外部专属目录：文件管理器可见、adb 直读、在分享白名单内
        base = await getExternalStorageDirectory();
      } catch (_) {
        base = null; // 部分 ROM / 桌面环境没有外部目录 → 走回落
      }
    }
    // 关闭开关时走私有 files/；外部目录不可用时也回落到这里（上层无感）
    base ??= await getApplicationSupportDirectory();
    final Directory target = Directory('${base.path}/speech_diag');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  /// 诊断目录的绝对路径（设置页「打开诊断目录」要显示 / 复制它）。
  static Future<String> dirPath() async => (await dir()).path;

  /// 目录里已落盘的诊断文件（**新的在前**，按文件名时间戳倒序）。
  static Future<List<File>> files() async {
    final Directory target = await dir();
    final List<File> found = <File>[];
    await for (final FileSystemEntity entity in target.list()) {
      if (entity is File) found.add(entity);
    }
    found.sort((File a, File b) => b.path.compareTo(a.path));
    return found;
  }

  /// 分享**最近一份**已落盘的诊断日志；目录为空时返回 null（调用方提示）。
  static Future<File?> shareLatest() async {
    final List<File> all = await files();
    if (all.isEmpty) return null;
    final File latest = all.first;
    await sharePath(latest.path); // 失败不抛，由 UI 提示（v1.21.28）
    return latest;
  }

  /// 「大导出」确认阈值（行）：达到就先让用户确认一次（B-P3）。
  static const int largeExportLineThreshold = 50000;

  /// 每写多少行 flush 一次（B-P3）。
  static const int flushEveryLines = 500;

  /// 是否需要「大导出」确认（纯函数，便于单测）。
  static bool needsLargeExportConfirm(int lineCount) =>
      lineCount >= largeExportLineThreshold;

  /// **唯一的落盘实现**：逐行写 + 每 [flushEveryLines] 行 flush 一次。
  ///
  /// 为什么不用 `file.writeAsString(buildText(...))`：那会先在内存里拼出**整串**
  /// （事件多时十几 MB）再交给平台写 —— 低端机上闪退的就是那一下。
  /// 这里任何时刻内存里只有一行。
  static Future<SpeechDiagWriteResult> writeLines({
    required Iterable<String> lines,
    required String path,
    void Function(int written)? onProgress,
  }) async {
    int written = 0;
    final IOSink sink = File(path).openWrite();
    try {
      for (final String line in lines) {
        sink.write('$line\n');
        written++;
        if (written % flushEveryLines == 0) {
          await sink.flush();
          onProgress?.call(written);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    final int bytes = await File(path).length();
    onProgress?.call(written);
    return SpeechDiagWriteResult(path: path, lines: written, bytes: bytes);
  }

  /// 在**隔离线程**里生成并写出（B-P3 的大导出路径）。
  ///
  /// [buildLines] 必须是**惰性**的：它在隔离线程里被逐行调用，格式化产生的中间串
  /// 不出这个 isolate，写完即回收。它本身会被**发到隔离线程**，所以只能捕获可发送
  /// 的纯数据 —— 不要捕获 `BuildContext` / 插件对象，也不要在里面读
  /// `SpeechDiagnostics.instance`（单例是**进程内**的，隔离线程里是另一份空实例，
  /// 事件会全丢）。
  static Future<SpeechDiagWriteResult> writeLinesIsolated({
    required Iterable<String> Function() buildLines,
    required String path,
  }) =>
      Isolate.run(() => writeLines(lines: buildLines(), path: path));

  /// 生产路径：落盘一份带时间戳的诊断日志。
  ///
  /// 行数达到 [largeExportLineThreshold] 时整段走隔离线程（UI 不卡，也没有逐行
  /// 进度回调，调用方用不确定进度条）；否则在主线程逐行写并按 [flushEveryLines]
  /// 报进度。
  static Future<SpeechDiagWriteResult> export({
    required bool includeAllEvents,
    void Function(int written)? onProgress,
  }) async {
    // 平台通道（path_provider）只能在主线程过，所以路径先在这里解析成字符串
    final Directory directory = await dir();
    final String path = '${directory.path}/speech_diag_${stamp()}.log';
    final Map<String, String> metaSnapshot = meta();
    final int estimate = SpeechDiagnostics.instance.estimateExportLines(
      includeAllEvents: includeAllEvents,
      meta: metaSnapshot,
    );
    if (needsLargeExportConfirm(estimate)) {
      final SpeechDiagnostics snapshot =
          SpeechDiagnostics.instance.detachedCopy();
      return writeLinesIsolated(
        path: path,
        buildLines: () => snapshot.exportLines(
          includeAllEvents: includeAllEvents,
          meta: metaSnapshot,
        ),
      );
    }
    return writeLines(
      lines: SpeechDiagnostics.instance.exportLines(
        includeAllEvents: includeAllEvents,
        meta: metaSnapshot,
      ),
      path: path,
      onProgress: onProgress,
    );
  }

  /// 落盘到 `app_flutter/speech_diag/speech_diag_<时间戳>.log`。
  static Future<SpeechDiagWriteResult> writeFile({
    required bool includeAllEvents,
    void Function(int written)? onProgress,
  }) =>
      export(includeAllEvents: includeAllEvents, onProgress: onProgress);

  /// 出现 🔴 时自动落盘用的固定文件名（覆盖写，避免堆一堆文件）。
  static Future<SpeechDiagWriteResult> writeRolling() async {
    final Directory directory = await dir();
    return writeLines(
      lines: SpeechDiagnostics.instance
          .exportLines(includeAllEvents: false, meta: meta()),
      path: '${directory.path}/speech_diag.log',
    );
  }

  /// 主路径：落盘后调系统分享面板。
  ///
  /// 返回落盘结果；调用方负责把「文件路径」也展示出来（分享被取消时
  /// 用户仍能靠路径自己取文件）。
  static Future<SpeechDiagWriteResult> shareFile({
    required bool includeAllEvents,
  }) async {
    final SpeechDiagWriteResult result =
        await writeFile(includeAllEvents: includeAllEvents);
    await sharePath(result.path); // 失败不抛，由 UI 提示（v1.21.28）
    return result;
  }

  /// 剪贴板体积上限（字节）：超过就**截断**（B-P4）。
  ///
  /// 500KB 这个数量级已经远超「粘进聊天窗口」能承受的长度，再大只会让输入框卡死。
  static const int clipboardByteLimit = 500 * 1024;

  /// 把**诊断日志**（`crash.log`）导出成一个文件（v1.21.19）
  ///
  /// 为什么需要：真机上的问题只能靠用户把日志发出来；而「复制到剪贴板」经过
  /// 聊天软件会被换行/截断污染（实测：贴进微信后每行都被腰斩，尾部参数全丢）。
  /// 导出成文件就能原样发过来。
  ///
  /// **不闪退的做法与朗读诊断导出完全一致**：走 [writeLines] 逐行流式写，
  /// 不把全文先拼成一个字符串；整个函数 try 住，任何失败都返回 null（UI 提示失败）。
  static Future<SpeechDiagWriteResult?> exportCrashLog() async {
    try {
      final String text = await CrashLog.read();
      final Directory dir = await SpeechDiagExport.dir();
      final List<String> lines = text.split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      return await writeLines(
        lines: lines,
        path: '${dir.path}/crash_${stamp()}.log',
      );
    } catch (_) {
      return null; // 导出失败不崩：UI 会提示，用户可以再试或走「复制全部」
    }
  }

  /// 分享指定文件；**绝不抛异常**，成功与否用返回值告诉调用方。
  ///
  /// v1.21.28：`share_plus` 走平台通道，`FileUriExposedException` 这类原生异常
  /// 一旦冒泡，轻则被应用级监听吞掉（用户看到"点了没反应"）、重则直接崩。
  /// 所以这里全包住，并把结果返回给 UI 去提示。
  static Future<bool> sharePath(String path) async {
    try {
      await Share.shareXFiles(
        <XFile>[XFile(path)],
        subject: '朗读诊断日志',
        text: '朗读诊断日志',
      );
      return true;
    } catch (_) {
      return false; // 分享面板不可用 / 被 ROM 拒绝：不影响已落盘的文件
    }
  }

  /// 降级路径：复制到剪贴板。
  ///
  /// B-P4：超过 [clipboardByteLimit] 时**按行截断**（不会切在半个字上），
  /// 并在文本尾部写明「已截断 + 全文多大」；返回值供 UI 提示用了多少 KB。
  static Future<SpeechDiagCopyResult> copyToClipboard({
    required bool includeAllEvents,
    int byteLimit = clipboardByteLimit,
  }) async {
    final List<String> kept = <String>[];
    int bytes = 0;
    int fullBytes = 0;
    bool truncated = false;
    for (final String line in SpeechDiagnostics.instance.exportLines(
      includeAllEvents: includeAllEvents,
      meta: meta(),
    )) {
      final int lineBytes = utf8.encode('$line\n').length;
      fullBytes += lineBytes;
      if (truncated) continue; // 已经截断：只继续统计全文体积
      if (bytes + lineBytes > byteLimit) {
        truncated = true;
        continue;
      }
      kept.add(line);
      bytes += lineBytes;
    }
    final String body = kept.join('\n');
    final String text = truncated
        ? '$body\n\n[已截断] 只复制了前 ${speechDiagSizeText(bytes)}'
            '（全文 ${speechDiagSizeText(fullBytes)}）。'
            '完整内容请用「导出」落盘，再用分享或 adb 取走。\n'
        : '$body\n';
    await Clipboard.setData(ClipboardData(text: text));
    return SpeechDiagCopyResult(
      bytes: bytes,
      fullBytes: fullBytes,
      truncated: truncated,
    );
  }
}

/// 人类可读体积（B-P4：SnackBar / 目录清单都显示 KB）。
String speechDiagSizeText(int bytes) => bytes < 1024
    ? '$bytes B'
    : '${(bytes / 1024).toStringAsFixed(1)} KB';

/// 剪贴板复制的结果。
class SpeechDiagCopyResult {
  const SpeechDiagCopyResult({
    required this.bytes,
    required this.fullBytes,
    required this.truncated,
  });

  /// 实际复制进去的正文体积（不含截断说明那几行）。
  final int bytes;

  /// 理论全文体积。
  final int fullBytes;

  final bool truncated;

  /// SnackBar 文案。
  String get message => truncated
      ? '已复制到剪贴板：前 ${speechDiagSizeText(bytes)}'
          '（全文 ${speechDiagSizeText(fullBytes)}，超出部分已截断）'
      : '已复制到剪贴板：${speechDiagSizeText(bytes)}';
}

/// 一次流式落盘的结果。
///
/// 只带 `path` 字符串、不带 `File` 对象：这个对象要**跨隔离线程**传回来
/// （见 [SpeechDiagExport.writeLinesIsolated]），路径字符串最省心。
class SpeechDiagWriteResult {
  const SpeechDiagWriteResult({
    required this.path,
    required this.lines,
    required this.bytes,
  });

  final String path;
  final int lines;
  final int bytes;

  File get file => File(path);

  /// 人类可读体积（B-P4 的 SnackBar 用）。
  String get sizeText => speechDiagSizeText(bytes);
}

/// 导出 / 复制结论（对话框 → 调用方：由调用方弹 SnackBar）。
class SpeechDiagExportOutcome {
  const SpeechDiagExportOutcome.ok(SpeechDiagWriteResult this.result)
      : error = null,
        copy = null;
  const SpeechDiagExportOutcome.copied(SpeechDiagCopyResult this.copy)
      : result = null,
        error = null;
  const SpeechDiagExportOutcome.failed(Object this.error)
      : result = null,
        copy = null;

  final SpeechDiagWriteResult? result;
  final SpeechDiagCopyResult? copy;
  final Object? error;

  bool get isOk => result != null || copy != null;
}
