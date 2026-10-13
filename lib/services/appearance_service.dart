import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'storage_service.dart';

/// 外观（背景图）的落地操作
///
/// 说明：原来这里还有一套「内置启动图标一键切换」（靠 Android 的
/// `activity-alias` 换桌面图标）。该功能**已按要求删除** ——
/// 它在不少 ROM 上表现不一致（切了没反应 / 图标缓存不刷新），
/// 属于"看着能用、实际不可靠"的功能，留着只会让用户以为坏了。
/// 现在只保留背景图相关的部分。
class AppearanceService {
  AppearanceService._();

  static final AppearanceService instance = AppearanceService._();

  /// 从相册选一张图作为界面背景
  ///
  /// 会**复制到应用目录**再使用：用户选的可能是临时缓存路径或需要权限的
  /// `content://` 位置，直接引用以后可能读不到（与「导入文件复制进应用目录」同理）。
  /// 返回落盘路径；用户取消或失败返回 null。
  Future<String?> pickBackgroundImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    final source = picked?.files.singleOrNull?.path;
    if (source == null || source.isEmpty) return null;
    final file = File(source);
    if (!await file.exists()) return null;

    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/theme');
    if (!await dir.exists()) await dir.create(recursive: true);
    // 固定文件名（后选的覆盖前一张），避免反复换图把目录撑大
    final extension = _extensionOf(source);
    final target = File('${dir.path}/background$extension');
    await file.copy(target.path);

    await StorageService.instance.setBackgroundImage(target.path);
    return target.path;
  }

  /// 清除背景图（连同落盘的副本一起删掉）
  Future<void> clearBackgroundImage() async {
    final current = StorageService.instance.backgroundImage;
    await StorageService.instance.setBackgroundImage('');
    if (current.isEmpty) return;
    try {
      final file = File(current);
      // 只删我们自己复制进来的那一份，别碰用户原图
      if (await file.exists() && file.path.contains('${Platform.pathSeparator}theme')) {
        await file.delete();
      }
    } catch (_) {
      // 删不掉不影响功能，下次换图会覆盖
    }
  }

  /// 切换启动图标；返回是否成功（桌面 / 不支持的 ROM 上会失败）
  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '.png';
    final ext = path.substring(dot).toLowerCase();
    // 只接受常见图片后缀，其余一律按 png 处理（图标解码按内容判断，后缀只是标识）
    const allowed = <String>{'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};
    return allowed.contains(ext) ? ext : '.png';
  }
}
