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

  // ── v1.21.44：选了自定义文件夹时，说明文案必须跟着落点变 ──────────────
  group('自定义文件夹时的说明文案', () {
    const String custom = '/storage/emulated/0/MyBooks';

    test('★落点在自选目录 → 文案必须说自选目录，且不许再说"系统下载目录下的专属文件夹"', () {
      final String hint = SettingsPage.downloadPathHint(inbox, customPath: custom);
      expect(hint, contains(custom),
          reason: '文件实际落在用户自选的目录，文案就得显示它');
      expect(hint, isNot(contains(inbox)),
          reason: '★选了自定义却还说"都放在 $inbox"= 骗用户（旧的固定文案就是这个毛病）');
      expect(hint, isNot(contains('系统公共「下载」目录下的一个专属文件夹')));
      // 方案 B 的两件事：① 现在用的是自定义位置 ② 不再走"下完再挪"
      expect(hint, contains('当前使用自定义保存位置'));
      expect(hint, contains('不再收纳到软件专属子文件夹'),
          reason: '★必须说清自定义路径不再走"下完再挪进专属子文件夹"那一步');
      expect(hint, isNot(contains('下完再挪')),
          reason: '自定义路径不经过"下载根目录→子文件夹"这套流程');
      // 这两条承诺在自定义路径下同样要成立
      expect(hint, contains('卸载本应用不会删掉'));
      expect(hint, contains('回退到应用私有目录'),
          reason: '自定义目录可能失效（被删 / 不可写），必须提前告知会降级');
      expect(hint, isNot(contains('云盘')),
          reason: '★用户明确要求：文案里不许出现"云盘"字样');
    });

    test('没设自定义时保持原文案（回归）', () {
      final String hint = SettingsPage.downloadPathHint(inbox);
      expect(hint, contains(inbox));
      expect(hint, isNot(contains('你自选的文件夹')));
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
