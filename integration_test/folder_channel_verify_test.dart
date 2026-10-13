import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备侧验证（v1.21.41）：**「打开下载文件夹」平台通道**
///
/// ## 为什么单独一条
///
/// Android 没有「打开某个目录」的标准 Intent，所以这件事交给原生侧尽力而为：
/// 三条路依次试（DocumentsContract 目录 URI / FileProvider 授权的 content URI
/// 配 resource斜杠folder / content URI 配通配 MIME），**能开返回 true，开不了 false**。
///
/// 这条用例要证明的是：
/// 1. **通道真的注册上了**（不会 `MissingPluginException`）——
///    Dart 侧那句"吞掉异常返回 false"太宽容，通道没挂也会静默变 false，
///    所以这里直接调通道，把异常暴露出来；
/// 2. 目录不存在时**明确返回 false**，而不是抛；
/// 3. 真实存在的目录，在**模拟器**上多半打不开（AOSP 没有认这个的文件管理器），
///    这是**允许**的 —— 此时应返回 false，让 Dart 侧退回"路径 + 清单"面板。
///    在用户的真机（一加 / ColorOS 有文件管理）上应当返回 true。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tts_reader/folder');

  testWidgets('通道已注册；目录不存在 → false（不抛）', (tester) async {
    await StorageService.instance.init();

    // ① 通道必须在（不在会抛 MissingPluginException，这条就是抓它的）
    Object? thrown;
    bool? result;
    try {
      result = await channel.invokeMethod<bool>('open', <String, Object?>{
        'path': '/data/user/0/com.example.tts_reader/绝对不存在的目录_12345',
      });
    } catch (e) {
      thrown = e;
    }
    // ignore: avoid_print
    print('DEVICE_VERIFY[folder-channel] 不存在的目录 → result=$result thrown=$thrown');
    expect(thrown, isNull,
        reason: '通道没注册会抛 MissingPluginException —— 那说明平台侧没挂上');
    expect(result, isFalse, reason: '目录不存在必须明确返回 false');
  });

  testWidgets('真实存在的目录 → 返回 true/false 都不抛（模拟器多半 false）',
      (tester) async {
    await StorageService.instance.init();
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/folder_probe');
    if (!await dir.exists()) await dir.create(recursive: true);

    final opened =
        await channel.invokeMethod<bool>('open', <String, Object?>{'path': dir.path});
    // ignore: avoid_print
    print('DEVICE_VERIFY[folder-channel] 存在的目录=${dir.path} 打开了=$opened');

    // 两种结果都是**合法**的：
    // · 模拟器没有认这个 Intent 的文件管理器 → false（Dart 侧退回面板）
    // · 真机（一加 / ColorOS 文件管理）能认 → true（直接跳过去）
    expect(opened, isNotNull, reason: '通道必须回一个明确结果，不能是 null');
  });

  testWidgets('公开下载目录也能问一遍（用户实际点的那条路）', (tester) async {
    await StorageService.instance.init();
    final opened = await channel.invokeMethod<bool>(
        'open', <String, Object?>{'path': StorageService.publicDownloadPath});
    // ignore: avoid_print
    print('DEVICE_VERIFY[folder-channel] 公共下载目录 '
        '${StorageService.publicDownloadPath} 打开了=$opened');
    expect(opened, isNotNull);
  });

  testWidgets('⚠️ 自定义到「外部存储」后，📂 要跳到**那个**文件夹（v1.21.41 追加）',
      (tester) async {
    await StorageService.instance.init();

    // 模拟用户在设置里点了「存到外部存储」
    final ext = await getExternalStorageDirectory();
    expect(ext, isNotNull,
        reason: '前置：这台设备要有外部私有目录（没有的话「存到外部存储」会提示）');
    final target = '${ext!.path}/downloads';
    final dir = Directory(target);
    if (!await dir.exists()) await dir.create(recursive: true);
    await StorageService.instance.setCustomDownloadPath(target);

    // 面板看到/原生打开用的都是这个路径
    final shown = await StorageService.instance.refreshDownloadPath();
    // ignore: avoid_print
    print('DEVICE_VERIFY[folder-channel] 自定义路径=$shown 目标=$target');
    expect(shown, target,
        reason: '自定义生效后，📂 该跳到自定义的那个文件夹，而不是系统「下载」');

    final opened =
        await channel.invokeMethod<bool>('open', <String, Object?>{'path': shown});
    // ignore: avoid_print
    print('DEVICE_VERIFY[folder-channel] 打开自定义目录=$opened '
        '（模拟器可能没有认这个的文件管理器 → false 也合法，'
        '此时 Dart 侧退回"路径+清单"面板）');
    expect(opened, isNotNull);

    await StorageService.instance.resetDownloadPath();
  });
}
