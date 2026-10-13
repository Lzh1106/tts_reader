import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **设置页「保存位置」卡的两处文案**（本轮 · 需求一）
///
/// ## 治的是什么（用户报的现象）
///
/// 1. 说明那行把**软件专属子文件夹名重复显示了两遍** —— 界面上是
///    `…/Download/桃花源阅读器/桃花源阅读器/`。
///    根因：文案里拼的是 `'$path/${StorageService.downloadInboxFolder}/'`，
///    而传进来的 `path` 已经是 `downloadInboxPath`，**本身就含那一层**。
/// 2. 「恢复默认」的 tooltip 写的是「恢复默认（`publicDownloadPath`）」=
///    `/storage/emulated/0/Download`（**根目录**）—— 但恢复默认之后文件并不
///    待在根目录，会被挪进专属子文件夹。tooltip 描述的是"默认去哪儿"，
///    就该显示最终落点。
///
/// ## 为什么值得单独钉住
///
/// 两处都只是文案，**改错了不容易被发现**（要滚到设置页最底下才看得到，
/// 而且要正好认识那两遍重复）。所以把它们抽成纯函数
/// （[SettingsPage.downloadPathHint] / [SettingsPage.downloadResetTooltip]），
/// 让"路径怎么拼、拼了几遍"能被直接断言，而不是靠肉眼看界面。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `downloadInboxPath` = 公共「下载」+ 软件专属子文件夹（= 文件最终待的地方）
  final String inbox = StorageService.instance.downloadInboxPath;
  const String folder = StorageService.downloadInboxFolder;

  group('「保存位置」说明文案', () {
    test('★子文件夹名只出现一次（治"重复两遍"）', () {
      final String hint = SettingsPage.downloadPathHint(inbox);
      expect(folder, '桃花源阅读器'); // 兜底：默认子文件夹名没被改掉
      expect(_countOf(hint, folder), 1,
          reason: '子文件夹名出现多次 = 路径被拼了两遍：$hint');
      expect(hint, contains(inbox));
      expect(hint, isNot(contains('$inbox/$folder')),
          reason: 'inbox 本身已含子文件夹名，不能再拼一次');
      // ignore: avoid_print
      print('DEVICE_VERIFY[download-hint] $hint');
    });

    test('仍然说清「下完再挪」与「卸载不删」（这两条不能丢）', () {
      final String hint = SettingsPage.downloadPathHint(inbox);
      expect(hint, contains('下完再挪'),
          reason: '必须解释"为什么不是直接下进子文件夹"');
      expect(hint, contains('卸载本应用也不会删掉'),
          reason: '用户最关心的就是这条');
    });
  });

  group('「恢复默认」tooltip', () {
    test('★说的是"默认最终落点"（含子文件夹），不是「下载」根目录', () {
      final String tip = SettingsPage.downloadResetTooltip(inbox);
      expect(tip, '恢复默认（$inbox）');
      expect(tip, contains(folder));
      // 旧文案的病根：把「下载」根目录当成默认落点。这条专门防它复发。
      expect(tip, isNot('恢复默认（${StorageService.publicDownloadPath}）'),
          reason: '根目录不是文件最终待的地方 —— 文件会被挪进子文件夹');
    });
  });
}

/// [needle] 在 [text] 里出现了几次（重叠不算，够用）
int _countOf(String text, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final int at = text.indexOf(needle, from);
    if (at < 0) return count;
    count++;
    from = at + needle.length;
  }
}
