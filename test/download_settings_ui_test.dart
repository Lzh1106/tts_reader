import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **下载设置页的文案与判据**（v1.21.40 真机截图暴露的 5 个 UI bug）
///
/// 截图现象（用户给的）：
/// ```
/// 保存位置
/// Directory: '/data/user/0/com.example.tts_reader/        ← 前缀 + 引号 + 丢子目录
/// 所以现在只能自定义**应用私有目录**里的文件夹。          ← 星号原样显示
/// 点「好」后仍按默认位置保存（系统「下载」目录）           ← 与副标题矛盾
/// ```
///
/// 分工：
/// - 「纯路径字符串」由 `test/browser_download_test.dart` 守（那条最容易回归）；
/// - 这里守**纯文本文案不许带 Markdown 星号**，以及**根目录判据**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  group('存储根判据（决定提示语说哪一句）', () {
    test('存储根 / 公共存储根都算"没进具体文件夹"', () {
      for (final root in <String>[
        '/',
        '/storage',
        '/storage/emulated',
        '/storage/emulated/0',
        '/sdcard',
        '/mnt/sdcard',
        '',
        '   ',
        '/storage/emulated/0/', // 末尾斜杠也要归一到根
      ]) {
        expect(SettingsPage.isPublicStorageRoot(root), isTrue,
            reason: '"$root" 应当判为"请先进入具体文件夹"');
      }
    });

    test('进了具体文件夹就不算根', () {
      for (final dir in <String>[
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Download/Books',
        '/storage/emulated/0/Android',
        '/sdcard/Books',
      ]) {
        expect(SettingsPage.isPublicStorageRoot(dir), isFalse,
            reason: '"$dir" 已经进了文件夹，不该说"请先进入具体文件夹"');
      }
    });
  });

  group('⚠️ 纯文本文案里不许出现 Markdown 星号', () {
    // Flutter 的 `Text` 不渲染 Markdown，星号会**原样显示给用户**。
    // §4.87 教程弹窗踩过同一个坑（`tutorial_dialog_test` 有断言守着那边），
    // 但没管到设置页这个对话框 —— v1.21.40 就栽在这里。
    testWidgets('设置页里所有文本都不含 ** 强调标记', (tester) async {
      // 设置页要读 TtsManager（引擎信息），必须给它 Provider
      await tester.pumpWidget(
        ChangeNotifierProvider<TtsManager>.value(
          value: TtsManager.instance,
          child: const MaterialApp(home: Scaffold(body: SettingsPage())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final List<String> offenders = <String>[];
      for (final widget in tester.widgetList<Text>(find.byType(Text))) {
        final String? data = widget.data;
        if (data != null && data.contains('**')) offenders.add(data);
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[settings-copy] 含星号的文本数=${offenders.length}');
      expect(offenders, isEmpty,
          reason: '这些文本会把星号原样显示给用户：\n${offenders.join('\n---\n')}');
    });
  });
}
