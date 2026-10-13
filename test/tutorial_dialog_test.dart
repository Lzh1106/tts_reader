import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/widgets/tutorial_dialog.dart';

/// 首次使用教程弹窗：
/// - 没看过才弹；看过后（勾了「不再显示」）不再弹；
/// - **三秒之内不能勾「不再显示」**（需求硬性要求），三秒后才放开；
/// - 勾了并确认 → 落盘；没勾就关掉 → 下次还会弹。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
  });

  /// 把弹窗挂在能拿 Navigator 的地方
  Future<void> pumpHost(WidgetTester tester, {ValueChanged<bool>? onResult}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final result = await TutorialDialog.maybeShow(context);
                  onResult?.call(result);
                },
                child: const Text('打开教程'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('默认没看过 → 会弹；弹窗内容都在', (tester) async {
    expect(StorageService.instance.tutorialDone, isFalse);
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('tutorial-dialog')), findsOneWidget);
    expect(find.text('欢迎使用桃花源阅读器'), findsOneWidget);
    expect(find.text('导入文档'), findsOneWidget);
    expect(find.text('开始朗读'), findsOneWidget);
    expect(find.text('朗读控制'), findsOneWidget);
    expect(find.text('朗读中的新能力'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tutorial-dont-show')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tutorial-start')), findsOneWidget);
  });

  testWidgets('教程说明按下即读（实测原版 1.20.0 就是单击即读）', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    // 实测：原版 1.20.0（v41）的 PDF 与文本都是**单击即读**，
    // 点一下就进入朗读模式并开始读，没有「双击进入」这一步。
    expect(
      find.textContaining('点一下句子就开始读'),
      findsOneWidget,
      reason: '教程要说明是点击即读',
    );
    expect(
      find.textContaining('之后点其他句子直接切换'),
      findsOneWidget,
      reason: '教程要说明点其他句子直接切换',
    );
    // 「双击进入」已经不存在，教程不该再这么写
    expect(
      find.textContaining('双击句子进入朗读模式'),
      findsNothing,
      reason: '双击进入朗读模式已回退掉，教程不该再写双击',
    );
    expect(
      find.textContaining('文本里双击句子'),
      findsNothing,
      reason: '双击进入朗读模式已回退掉，教程不该再写双击',
    );
  });

  testWidgets('教程区分方块键的两种语义（文档库整条消失 / 阅读页收起成小圆盘）',
      (tester) async {
    // §4.92 + §4.101：方块键在文档库和阅读页是**两种**行为。
    // 教程原来只写「方块键结束朗读」，用户按了会发现跟说的不一样 ——
    // 这条用例把「必须区分」钉死。
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('方块键在文档库里按'),
      findsOneWidget,
      reason: '教程要说明文档库方块键的语义',
    );
    expect(
      find.textContaining('控制栏整条消失'),
      findsOneWidget,
      reason: '文档库方块键 = 整条消失',
    );
    expect(
      find.textContaining('在阅读页里按'),
      findsOneWidget,
      reason: '教程要说明阅读页方块键的语义',
    );
    expect(
      find.textContaining('只收起成小圆盘'),
      findsOneWidget,
      reason: '阅读页方块键 = 收起成迷你条，会话保留（§4.92）',
    );
    // 文案里不该出现 Markdown 记号（Text 不会渲染 ** 加粗）
    expect(find.textContaining('**'), findsNothing,
        reason: '教程正文里不该出现 Markdown 的星号');
  });

  testWidgets('教程覆盖 v1.21 之后的新交互（自动连读 / 退出后继续 / 换歌语义）',
      (tester) async {
    // §4.100 任务 E + v1.21.1：这些能力教程原来一条都没提。
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('自动连读'),
      findsOneWidget,
      reason: 'v1.21.1 的自动连读要写进教程',
    );
    expect(
      find.textContaining('自动翻页'),
      findsOneWidget,
      reason: 'v1.21.1 的自动翻页要写进教程',
    );
    expect(
      find.textContaining('退出阅读页回文档库，朗读继续'),
      findsOneWidget,
      reason: '§4.60「退出不打断朗读」要写进教程',
    );
    expect(
      find.textContaining('就像音乐播放器换歌'),
      findsOneWidget,
      reason: '§4.100 任务 E 的换歌语义要写进教程',
    );
    expect(
      find.textContaining('朗读位置会自动记住'),
      findsOneWidget,
      reason: '§4.100 任务 D 的位置记忆要写进教程',
    );
  });

  testWidgets('教程覆盖网页翻译与下载（v1.21.36 新增）', (tester) async {
    // 为什么加这一条：翻译选路改成「谷歌优先 + 百度兜底」之后，
    // 用户会看到"翻译出来的界面跟平时不是一家"，教程必须提前说明；
    // 下载走系统下载管理器、目录可改，也是用户第一次会问的事。
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    expect(find.text('网页翻译与下载'), findsOneWidget,
        reason: '教程要有这一节');
    expect(
      find.textContaining('优先用谷歌整页翻译'),
      findsOneWidget,
      reason: '要说明首选谷歌（用户明确要求"改回默认谷歌"）',
    );
    expect(
      find.textContaining('自动改用百度'),
      findsOneWidget,
      reason: '要说明兜底是百度、且会自动切换',
    );
    expect(
      find.textContaining('交给系统下载管理器'),
      findsOneWidget,
      reason: '要说明下载走系统下载管理器',
    );
    // ⚠️ 教程里**不该**再提 Edge / 微软翻译：那条链路已在 v1.21.36 删除，
    // 也不该提"扩展商店"（实测在 WebView 里必然引去装 Edge，已按用户决定撤掉）
    expect(find.textContaining('Edge 翻译'), findsNothing,
        reason: '微软翻译链路已删，教程不该再提');
    expect(find.textContaining('扩展商店'), findsNothing,
        reason: '扩展商店入口已移除，教程不该再提');
  });

  testWidgets('三秒内不能勾选「不再显示」，三秒后可以', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    final checkbox = find.byKey(const ValueKey<String>('tutorial-dont-show'));

    // 刚打开：勾选是禁用的
    var widget = tester.widget<Checkbox>(checkbox);
    expect(widget.onChanged, isNull, reason: '三秒之内不该允许勾选');
    expect(find.textContaining('读完 3 秒后可勾选'), findsOneWidget);

    // 等 2 秒：还是禁用
    await tester.pump(const Duration(seconds: 2));
    widget = tester.widget<Checkbox>(checkbox);
    expect(widget.onChanged, isNull, reason: '才过 2 秒，仍不该允许勾选');

    // 再等 2 秒（累计 4 秒）：放开
    await tester.pump(const Duration(seconds: 2));
    widget = tester.widget<Checkbox>(checkbox);
    expect(widget.onChanged, isNotNull, reason: '超过 3 秒应当允许勾选');
    expect(find.text('不再显示这个教程'), findsOneWidget);

    // 真的能勾上
    await tester.tap(checkbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
  });

  testWidgets('勾了「不再显示」并确认 → 落盘，之后不再弹', (tester) async {
    bool? result;
    await pumpHost(tester, onResult: (value) => result = value);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    // 等过 3 秒再勾
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const ValueKey<String>('tutorial-dont-show')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('tutorial-start')));
    await tester.pumpAndSettle();

    expect(result, isTrue, reason: '应当把「不再显示」传出去');
    expect(StorageService.instance.tutorialDone, isTrue, reason: '应当落盘');

    // 再点一次：这次不弹
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tutorial-dialog')), findsNothing,
        reason: '看过了就不该再弹');
  });

  testWidgets('没勾「不再显示」就关掉 → 下次还会弹', (tester) async {
    bool? result;
    await pumpHost(tester, onResult: (value) => result = value);
    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();

    // 不勾，直接开始使用
    await tester.tap(find.byKey(const ValueKey<String>('tutorial-start')));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(StorageService.instance.tutorialDone, isFalse,
        reason: '没勾就不该记录「看过了」');

    await tester.tap(find.text('打开教程'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tutorial-dialog')), findsOneWidget,
        reason: '没勾「不再显示」应当还会弹');
  });

  testWidgets('「不再显示」的勾选会落盘并读回', (tester) async {
    await StorageService.instance.setTutorialDone(true);
    StorageService.instance.resetForTest();
    await StorageService.instance.init();
    expect(StorageService.instance.tutorialDone, isTrue);
  });
}
