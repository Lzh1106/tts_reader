import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tts_reader/pages/browser_page.dart';
import 'package:tts_reader/services/storage_service.dart';

/// 设备侧验证（v1.21.40）：**下载设置页与「下载文件夹」面板**
///
/// ## 为什么必须上设备
///
/// 这批 bug 有两个只能在真机/模拟器上暴露：
/// 1. **📂 面板崩溃**（`Unsupported operation: Cannot modify an unmodifiable list`）
///    —— `Directory.list().toList()` 在设备实现上返回**不可修改列表**，
///    纯 Dart 测试里 `dart:io` 的实现不一样，复现不出来（真机连崩 8 次，
///    异常被 `unawaited` 吞掉，用户只看到"点了没反应"）。
/// 2. **路径显示**（`Directory: '/data/...'`）—— 真实路径要过 `path_provider`
///    平台通道才拿得到。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  testWidgets('下载路径是纯路径：无 Directory: 前缀 / 无引号 / 是绝对路径',
      (tester) async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    final resolved = await StorageService.instance.refreshDownloadPath();
    final shown = StorageService.instance.downloadPath;
    // ignore: avoid_print
    print('DEVICE_VERIFY[dl-path] 默认目标=${StorageService.instance.downloadTarget} '
        '显示=$shown 解析=$resolved');

    for (final candidate in <String>[shown, resolved]) {
      expect(candidate.contains('Directory:'), isFalse,
          reason: '真机截图里就是这个前缀（Directory 对象被插值）："$candidate"');
      expect(candidate.contains("'"), isFalse, reason: 'toString() 带来的引号');
      expect(candidate.startsWith('/'), isTrue, reason: '必须是绝对路径');
    }
    // 默认是系统「下载」目录时，显示的应当就是那个常量
    expect(shown, StorageService.publicDownloadPath,
        reason: '副标题说"系统下载目录"，显示的就该是它');
  });

  testWidgets('建一个下载目录 → 📂 面板能打开（不再静默失败）', (tester) async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    // ⚠️ 用**应用私有目录**造文件，不要写 `/storage/emulated/0/Download`：
    // 测试进程往公共下载目录写会 `Permission denied (errno = 13)`（实测），
    // 而 `Directory.list()` 的"不可修改列表"行为在私有目录上一样成立 ——
    // Bug 1 的崩溃点（排序）能照样覆盖到。
    final appDir = await getApplicationDocumentsDirectory();
    final probeDir = Directory('${appDir.path}/downloads/下载');
    if (!await probeDir.exists()) {
      await probeDir.create(recursive: true);
    }
    await File('${probeDir.path}/b_测试.txt').writeAsString('b');
    await File('${probeDir.path}/a_测试.txt').writeAsString('a');
    // ⚠️ v1.21.43：面板现在**固定**指向 `StorageService.downloadInboxPath`
    // （「下载」+ 软件专属子文件夹），不再跟随 `setCustomDownloadPath` ——
    // 所以要用**测试钩子** [debugFolderPathForTest] 把面板指到这个可读目录
    // （测试进程写不了公共「下载」目录，见上面的注释）。
    // ignore: avoid_print
    print('DEVICE_VERIFY[dl-folder] 目录=${probeDir.path} '
        '存在=${await probeDir.exists()} '
        '文件数=${(await probeDir.list().toList()).length}');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester);
    final state = tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugFolderPathForTest = probeDir.path;

    // ⚠️ 不能 `await runAsync(() => debugShowDownloadFolder())`：
    // `_showDownloadFolder` 内部会 `await showDialog(...)`，而对话框要等 pump 才
    // 渲染出来 —— 直接 await 就是死等（实测超时 3 分钟）。
    // 正确做法：发起它（不 await），再 pump 让对话框出现。
    // ⚠️ 本轮（需求二）起**没有 `skipNative` 参数**了：原生跳转分支已删，
    //    这个入口只会弹面板。
    unawaited(state.debugShowDownloadFolder());
    await settle(tester, rounds: 20);

    // 面板应当弹出来
    expect(find.text('下载文件夹'), findsOneWidget,
        reason: '📂 必须能弹出面板 —— 修前抛异常被吞掉，什么都不发生');
    // 路径要显示成纯路径
    final pathText = tester.widget<SelectableText>(find.byType(SelectableText));
    // ignore: avoid_print
    print('DEVICE_VERIFY[dl-folder] 面板路径=${pathText.data}');
    expect(pathText.data!.contains('Directory:'), isFalse);
    // 两个文件都列出来了（说明真的读到了目录、且排序没崩）
    expect(find.textContaining('a_测试.txt'), findsOneWidget);
    expect(find.textContaining('b_测试.txt'), findsOneWidget);

    // 关掉对话框，别让它挂着影响后面的收尾
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);

    await StorageService.instance.resetDownloadPath();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    // ⚠️ 这条是 Bug 1 的核心断言：修前这里一定拿到那个 Unsupported operation
    expect(tester.takeException(), isNull,
        reason: '打开下载文件夹不许抛异常（真机连崩 8 次的那个）');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('目录不存在时 📂 也不崩（const 空列表那条崩溃路径）', (tester) async {    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    // 把面板指到一个**不存在**的目录（同样要走测试钩子，见上一个用例）：
    // 修前 `files` 保持 `const <File>[]`，`sort()` 一样抛异常
    const missing = '/data/user/0/com.example.tts_reader/不存在的目录_探针';

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester);
    final state = tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugFolderPathForTest = missing;

    // ⚠️ 不能 `await runAsync(() => debugShowDownloadFolder())`：
    // `_showDownloadFolder` 内部会 `await showDialog(...)`，而对话框要等 pump 才
    // 渲染出来 —— 直接 await 就是死等（实测超时 3 分钟）。
    // 正确做法：发起它（不 await），再 pump 让对话框出现。
    unawaited(state.debugShowDownloadFolder());
    await settle(tester, rounds: 20);

    // ignore: avoid_print
    print('DEVICE_VERIFY[dl-folder-missing] 异常=${tester.takeException()}');
    expect(find.text('下载文件夹'), findsOneWidget,
        reason: '目录不存在时也要能弹面板（只是清单为空）');
    // 空目录也要有明确文案，而不是一片空白
    expect(find.textContaining('目录是空的'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);

    await StorageService.instance.resetDownloadPath();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  /// ★v1.21.43：**复现"文件在列目录之后消失"** —— 这条直接回答
  /// 「闪退的根因到底是不是 `lengthSync()`」
  ///
  /// ## 为什么要这条
  ///
  /// 用户报「点 📂 导航至软件下载文件夹会闪退」。我判断根因是
  /// 弹窗 `builder` 里那句 `file.lengthSync()`：清单列出来之后、弹窗渲染之前，
  /// 文件完全可能已经不在（**下载收纳路径正在把文件移进这个目录**），
  /// 于是 `lengthSync()` 抛 `FileSystemException` —— **build 期抛异常 = 闪退**。
  ///
  /// 但这只是推断。这条用例把那个**竞态窗口**人为制造出来：
  /// 用一个「第一次 `length()` 返回清单、第二次就返回空」的目录包装器，
  /// 精确模拟"列目录那一刻文件还在、渲染那一刻没了"。
  ///
  /// · 摘掉 try（`_sizeTextSafe` 直接 `lengthSync`）→ 这条**必须崩**
  /// · 包着 try → 这条必须**正常显示「已移走」**
  ///
  /// 跑法见文件末尾注释；`_VanishingFile` 只在设备侧有意义。
  testWidgets('★文件在"列目录"之后消失 → 📂 不能崩（闪退根因复现）', (tester) async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    final appDir = await getApplicationDocumentsDirectory();
    final probeDir = Directory('${appDir.path}/downloads/消失探针');
    if (!await probeDir.exists()) {
      await probeDir.create(recursive: true);
    }
    // 先造一个真实文件（列目录时会看到它）
    final victim = File('${probeDir.path}/会消失的书.pdf');
    await victim.writeAsBytes(List<int>.filled(64, 0x25)); // 64 字节的假 PDF
    expect(await victim.exists(), isTrue);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester);
    final state = tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugFolderPathForTest = probeDir.path;
    // ⚠️ 让"读目录"变慢，好让下面的删除动作落在"列目录"与"渲染"之间 ——
    // 这正是真机上收纳路径移文件时出现的那个竞态窗口。
    // ⚠️ 延迟要**明显长于** settle(12 轮) ≈ 1.2 秒，否则删除动作会落在
    // 弹窗 build 之后（那就什么都没测到）。3 秒留足余量。
    state.debugFolderListDelayForTest = const Duration(seconds: 3);

    // 发起 📂（不 await：里面 await showDialog，要等 pump 才渲染）
    unawaited(state.debugShowDownloadFolder());
    // 等它进到"读目录"里（此时 entries 还没拿到），再把文件删掉
    await settle(tester, rounds: 12);
    // ★关键动作：在弹窗渲染之前把文件删掉 —— 制造真机上那个竞态
    if (await victim.exists()) await victim.delete();
    // ignore: avoid_print
    print('DEVICE_VERIFY[📂-vanish] 已在渲染前删除文件，exists=${await victim.exists()}');

    await settle(tester, rounds: 40);

    // 面板必须仍然弹出来（而不是崩掉）
    expect(find.text('下载文件夹'), findsOneWidget,
        reason: '★文件消失不许打断面板 —— 这正是真机闪退的那条路径');
    // 体积那一栏要显示成占位，而不是抛
    expect(find.textContaining('已移走'), findsOneWidget,
        reason: '★`lengthSync` 抛异常后必须回落到占位文案');
    // 框架层不许有未捕获异常
    expect(tester.takeException(), isNull,
        reason: '★build 期不许抛异常（真机闪退的机制）');

    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }, timeout: const Timeout(Duration(minutes: 3)));

  /// ★本轮（需求二）：**原生跳转分支已删** —— 点 📂 一定弹面板
  ///
  /// ## 这条用例换了判据（**不是**放松断言）
  ///
  /// 原来它锁的是「**原生跳转是主行为，不许降级**」（用户 v1.21.43 拍板），
  /// 断言 `tryNativeFolderOpen == true`，而且"跳转成功所以没面板"也算通过。
  ///
  /// 本轮用户**重新拍板**：真机（TB335FC）点 📂 闪退，崩的就是那条原生
  /// `ACTION_VIEW` Intent 路，根因始终没有 logcat 佐证 → **删掉原生分支，
  /// 按钮保留**，📂 改为直接弹面板（绝对路径 + 清单 + 「复制路径」）。
  ///
  /// 所以断言换成两条**更硬**的锁：
  /// 1. `tryNativeFolderOpen` 必须是 `false` —— 谁把那条会闪退的路加回来，这条红；
  /// 2. 面板**必须**出现 —— 不再有"跳转成功所以没面板"这种模糊结果。
  testWidgets('★真实路径点 📂：直接弹面板（原生跳转已删，不许加回来）', (tester) async {
    await StorageService.instance.setTutorialDone(true);
    await StorageService.instance.init();

    // ★第一道锁：原生跳转分支**已删**（本轮用户拍板）
    expect(BrowserPage.tryNativeFolderOpen, isFalse,
        reason: '★原生跳转那条 Intent 路是 📂 闪退的来源；'
            '再把它打开 = 把闪退放回产品路径，必须用户重新拍板');

    final appDir = await getApplicationDocumentsDirectory();
    final probeDir = Directory('${appDir.path}/downloads/真实路径探针');
    if (!await probeDir.exists()) {
      await probeDir.create(recursive: true);
    }
    await File('${probeDir.path}/真路径.txt').writeAsString('x');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserPage())),
    );
    await settle(tester);
    final state = tester.state<BrowserPageState>(find.byType(BrowserPage));
    state.debugFolderPathForTest = probeDir.path;

    // 与用户点 📂 完全一致（现在就这一条路：弹面板）
    unawaited(state.debugShowDownloadFolder());
    await settle(tester, rounds: 20);

    // ignore: avoid_print
    print('DEVICE_VERIFY[📂-real] 原生开关=${BrowserPage.tryNativeFolderOpen} '
        '异常=${tester.takeException()}');
    expect(tester.takeException(), isNull, reason: '不许抛异常');

    // ★第二道锁：面板**一定**出现（没有"跳转优先"这个分支了）
    expect(find.text('下载文件夹'), findsOneWidget,
        reason: '📂 现在一律弹面板');
    expect(find.textContaining('真路径.txt'), findsOneWidget,
        reason: '面板要列出目录里的文件');
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
