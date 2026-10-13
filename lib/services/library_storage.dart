import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'file_naming.dart';

/// 收进书库的结果
class AdoptResult {
  const AdoptResult({
    required this.path,
    required this.copied,
    this.reused = false,
    this.error,
  });

  /// 最终使用的路径（复制成功就是书库里的副本）
  final String path;

  /// 是否真的复制了一份
  final bool copied;

  /// 是否复用了已有的同名同大小副本（重复导入同一本书）
  final bool reused;

  /// 复制失败的原因（失败时 [path] 仍是原路径，功能照常，只是不够稳）
  final String? error;

  bool get ok => error == null;
}

/// 书库目录：**导入时把文件收进应用私有目录**，文档库不再依赖外部路径
///
/// 为什么必须复制：Android 上 file_picker 会把用户选的文件**复制到缓存目录**
/// （`cache/file_picker/<时间戳>/<名字>`）再交给应用，缓存随时可能被系统清掉，
/// 那时文档库里的书就打不开了。
///
/// 复制时**保持原文件名**（只清洗非法字符），重名按 Android 习惯加 ` (1)`；
/// 已经在应用私有目录里的文件（比如下载目录下的）不再复制一份。
class LibraryStorage {
  LibraryStorage._();

  /// 书库子目录名（位于应用私有文档目录下）
  static const String dirName = 'books';

  /// 书库目录，不存在则创建
  static Future<Directory> booksDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 应用私有目录（书库、下载都在它下面）
  static Future<String> appDirPath() async {
    final base = await getApplicationDocumentsDirectory();
    return _normalize(base.path);
  }

  /// 路径是否已经在应用私有目录里
  ///
  /// 是的话就不用再复制：下载目录、书库目录都在这里，
  /// 而 file_picker 的缓存副本在 `cache/` 下（不在应用文档目录里），需要复制。
  static Future<bool> isInAppDir(String path) async {
    final app = await appDirPath();
    final target = _normalize(path);
    return target == app || target.startsWith('$app/');
  }

  /// 是否是我们自己的书库副本（删除文档时只删这里的）
  static Future<bool> isLibraryCopy(String path) async {
    final dir = await booksDir();
    final prefix = _normalize(dir.path);
    final target = _normalize(path);
    return target.startsWith('$prefix/');
  }

  /// 把外部文件收进书库目录
  ///
  /// - [name] 是原始文件名（选择器报的那个）；不给就用 [path] 的末段；
  /// - 已在应用私有目录 → 原样返回，不复制；
  /// - 书库里有同名同大小的副本 → 复用（重复导入同一本书不会存两份）；
  /// - 复制失败 → 返回原路径并带上 [AdoptResult.error]，不阻断导入。
  static Future<AdoptResult> adopt(String path, {String? name}) async {
    // 整段兜底：复制只是「让书更稳」，任何一步失败都不该让导入失败
    try {
      final source = File(path);
      if (!source.existsSync()) {
        return AdoptResult(path: path, copied: false, error: '文件不存在');
      }
      if (await isInAppDir(path)) {
        // 已经在应用私有目录里（下载目录 / 上次导入的副本）：不用再复制一份
        return AdoptResult(path: path, copied: false);
      }
      return await _copyInto(source, path, name);
    } catch (error) {
      return AdoptResult(path: path, copied: false, error: _describe(error));
    }
  }

  static Future<AdoptResult> _copyInto(File source, String path, String? name) async {
    final dir = await booksDir();
    final rawName = (name != null && name.trim().isNotEmpty) ? name : path;
    var wanted = FileNaming.sanitize(FileNaming.baseName(rawName));
    if (wanted.isEmpty) {
      wanted = '未命名_${DateTime.now().millisecondsSinceEpoch}';
    }
    final separator = Platform.pathSeparator;
    // 同名同大小：当作同一本书，复用已有副本（避免重复导入时存两份大文件）
    final existing = File('${dir.path}$separator$wanted');
    if (existing.existsSync() && existing.lengthSync() == source.lengthSync()) {
      return AdoptResult(path: existing.path, copied: false, reused: true);
    }
    final fileName = FileNaming.uniqueName(
      wanted,
      (candidate) => File('${dir.path}$separator$candidate').existsSync(),
    );
    final target = '${dir.path}$separator$fileName';
    try {
      await source.copy(target);
      return AdoptResult(path: target, copied: true);
    } catch (error) {
      return AdoptResult(path: path, copied: false, error: _describe(error));
    }
  }

  /// 删除书库副本（文档从文档库移除时调用）
  ///
  /// 只删 [booksDir] 里的文件：下载目录、公共下载目录里的原文件不动。
  static Future<bool> release(String path) async {
    try {
      if (!await isLibraryCopy(path)) return false;
      final file = File(path);
      if (!file.existsSync()) return false;
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 统一分隔符，便于前缀比较
  static String _normalize(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

  static String _describe(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}
