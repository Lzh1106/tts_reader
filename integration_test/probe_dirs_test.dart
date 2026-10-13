import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// **一次性探针**：打印三个候选下载目录的真实路径，供 adb 侧做
/// 「卸载应用后文件还在不在」的实测。
///
/// 不参与常规测试套件（放在 integration_test 下、只在手动跑时执行）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('打印目录路径', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    Directory? ext;
    try {
      ext = await getExternalStorageDirectory();
    } catch (_) {
      ext = null;
    }
    // ignore: avoid_print
    print('PATHS docs=${docs.path}');
    // ignore: avoid_print
    print('PATHS support=${support.path}');
    // ignore: avoid_print
    print('PATHS external=${ext?.path ?? "(null)"}');

    // 在每个目录下各写一个探针文件
    for (final entry in <String, Directory?>{
      'docs': docs,
      'support': support,
      'external': ext,
    }.entries) {
      final dir = entry.value;
      if (dir == null) continue;
      final probe = Directory('${dir.path}/uninstall_probe');
      if (!await probe.exists()) await probe.create(recursive: true);
      await File('${probe.path}/keep_me.txt').writeAsString('${entry.key} 探针');
      // ignore: avoid_print
      print('PATHS wrote ${probe.path}/keep_me.txt');
    }

    // ⚠️ 写完**挂住不退出**，给 adb 侧留出"手动卸载 + 观测"的窗口。
    // 正常跑完的话 `flutter test` 会自动卸载应用，文件当场就没了，观测不到。
    // ignore: avoid_print
    print('PATHS 挂住 90 秒，等外部 adb 卸载…');
    for (var i = 0; i < 90; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
    }
    // ignore: avoid_print
    print('PATHS 挂住结束');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
