import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/features/pdf_reading/pdf_page_turn_controller.dart';

/// 自动翻页闸门的纯逻辑测试。
///
/// 这些规则都是**踩过坑才写下来的**（HANDOFF §4.58 / §4.90），
/// 用真机复现一次很贵，所以在这里用注入的「落位动作」钉死：
///
/// - 当前页只能由「动画落地」更新（不能读 `controller.page`）；
/// - 跨度 > 2 页必须瞬时跳（否则逐页渲染 = 用户看到的「疯狂快速翻页」）；
/// - 相邻页保留动画；
/// - 落位与 setState 放帧后（build 期调用会炸）；
/// - 用户手动翻页期间不自动翻。
class _FakePageChannel {
  /// 记录每一次「落到第几页」的请求，以及是瞬时还是动画
  final List<(int page, bool instant)> turns = <(int, bool)>[];

  late final PageController controller = PageController();

  /// 同步执行的「帧后调度」——测试里不需要真的等帧
  void Function(VoidCallback) get immediateScheduler =>
      (callback) => callback();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePageChannel channel;

  setUp(() {
    channel = _FakePageChannel();
  });

  PdfPageTurnController make({int pageCount = 10, int animateLimit = 2}) {
    final c = PdfPageTurnController(
      pageCount: pageCount,
      animateLimit: animateLimit,
      animationDuration: const Duration(milliseconds: 10),
      settleTimeout: const Duration(milliseconds: 200),
    );
    c.scheduleAfterFrame = channel.immediateScheduler;
    c.jumpTo = (page) => channel.turns.add((page, true));
    c.animateTo = (page, _) => channel.turns.add((page, false));
    return c;
  }

  test('初始页是 0；只有落地回调能改当前页', () {
    final c = make();
    // 不 attach：只验状态机
    expect(c.displayedPage, 0);

    c.onPageSettled(4);
    expect(c.displayedPage, 4, reason: 'onPageSettled 是唯一更新当前页的入口');
    expect(c.isTurning, isFalse);
  });

  test('attach 时按 initialPage 落位，并夹取越界值', () {
    final c = make(pageCount: 5);
    c.attach(initialPage: 3);
    expect(c.displayedPage, 3);

    final c2 = make(pageCount: 5);
    c2.attach(initialPage: 99);
    expect(c2.displayedPage, 4, reason: '越界要夹到最后一页（0 起）');
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · P0-2：换书复位
  //
  // 真机症状：切书后点「继续」→ 不显示高亮 / 不跳转朗读页 / 跳错页。
  // 根因：`_userDriven` 只有三处会清（都在"同一本书内"），换书路径一处都没有
  // → 用户滑动过页面再切书，之后每一次跟读都被静默挡下。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ P0-2：换书必须复位闸门（否则跟读被静默挡下）', () {
    test('★核心：用户滑动过页 + 页面位置相同 → 换书后必须能自动跟读', () {
      final c = make(pageCount: 10);
      // ① 用户手动滑了一下（真机：手指拖动 → markUserDriven），并落位到第 1 页
      c.markUserDriven();
      c.onPageSettled(1);
      expect(c.userDriven, isTrue);

      // ⚠️ 判据设计的关键：**目标页取"与当前页不同"的值**。
      // 用相同页（turnTo(1)）会被 `target == _displayedPage` 那条
      // 「已经在目标页 → return true」**顺带满足**，于是 `_userDriven`
      // 是不是被复位根本验不到 —— 我第一版就这么写，退化后用例照样绿（假测试）。
      expect(c.turnTo(5), isFalse,
          reason: '不换书时，用户手动翻页期间不该自动翻（原有语义，别弄坏）');

      // ② 换到另一本书（**初始页与复位前相同**，排除"页码复位"这个干扰变量）
      c.resetForDocument(pageCount: 10, initialPage: 1);
      expect(c.userDriven, isFalse, reason: '换书必须清掉"用户手动翻页"标记');
      expect(c.displayedPage, 1, reason: '前置：页码跟前一本书一样，'
          '这样下面那条 turnTo 就**只**能靠 _userDriven 通过');

      // ③ 新书的跟读必须能翻页 —— 这一步只可能因为 `_userDriven` 没清而失败
      expect(c.turnTo(5), isTrue,
          reason: '★真机症状就在这里：原来这一步返回 false → '
              'onSentenceChanged 又把返回值丢了 → 高亮不显示、不跳页');
    });

    test('换书清掉落位中的 _turning 与兜底定时器', () async {
      final c = make(pageCount: 10);
      c.turnTo(1); // 相邻页 → 走动画，_turning 置真
      expect(c.isTurning, isTrue);
      // 换书
      c.resetForDocument(pageCount: 10, initialPage: 0);
      expect(c.isTurning, isFalse, reason: '换书不能带着"上一本还没落位"的状态');
      // 兜底定时器若还活着，会在新书上乱放 _turning —— 等过它的超时确认没有副作用
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(c.isTurning, isFalse);
    });

    test('不传 initialPage 时落到第 0 页，并按新页数夹取', () {
      final c = make(pageCount: 3);
      c.onPageSettled(2);
      c.resetForDocument(pageCount: 10);
      expect(c.displayedPage, 0, reason: '没给初始页就回到第 0 页');

      final c2 = make(pageCount: 10);
      c2.onPageSettled(9);
      c2.resetForDocument(pageCount: 3, initialPage: 99);
      expect(c2.displayedPage, 2, reason: '越界要按**新**页数夹取');
    });

    test('PDF→PDF 切书：旧书页码不会留在闸门里', () {
      final c = make(pageCount: 300);
      c.onPageSettled(120); // 上一本读到 120 页
      c.resetForDocument(pageCount: 5, initialPage: 0);
      // 新书只有 5 页：若旧页码残留，turnTo 会拿 120 去算跨度
      expect(c.displayedPage, 0);
      expect(c.turnTo(4), isTrue, reason: '新书内相邻页照常走动画');
    });
  });

  test('已经在目标页：不翻页，但闸门归位', () {
    final c = make();
    c.onPageSettled(2);
    expect(c.turnTo(2), isTrue, reason: '已在目标页算成功');
    expect(channel.turns, isEmpty, reason: '不该发出多余的翻页');
  });

  test('相邻页（跨度 1）：走动画', () {
    final c = make();
    c.attach();
    expect(c.turnTo(1), isTrue);
    expect(c.isTurning, isTrue, reason: '动画落地前闸门是关的');
  });

  test('跨度 > 2 页：瞬时跳（不能逐页动画）', () {
    final c = make(pageCount: 200);
    c.attach();
    c.onPageSettled(0);

    // 第 1 页 → 第 148 页
    expect(c.turnTo(147), isTrue);
    expect(c.displayedPage, 147,
        reason: '大跨度要**先记账再跳**：即使 onPageChanged 不回调也不会重复翻');
    expect(c.isTurning, isFalse, reason: '瞬时跳不算「正在翻页」');
  });

  test('跨度恰好 2 页：仍在动画档（边界）', () {
    final c = make(pageCount: 200, animateLimit: 2);
    c.attach();
    c.onPageSettled(0);
    c.turnTo(2); // 距离 2，不超过 animateLimit
    expect(c.isTurning, isTrue, reason: '距离 2 不走瞬时跳');
  });

  test('上一次还没落地：新的请求让位（不会连翻）', () {
    final c = make(pageCount: 200);
    c.attach();
    c.onPageSettled(0);
    c.turnTo(1);
    expect(c.isTurning, isTrue);

    // 动画途中又来一个请求：让位
    expect(c.turnTo(2), isFalse, reason: '正在翻页时新请求要被挡下');
  });

  test('force 可以突破「正在翻页」与「用户手动翻页」两道闸门', () {
    final c = make(pageCount: 200);
    c.attach();
    c.markUserDriven();
    // 用户手动翻页期间：普通请求被挡
    expect(c.turnTo(3), isFalse, reason: '用户手动翻页期间不自动翻');

    // 「回到朗读位置」是显式指令 → force
    expect(c.turnTo(3, force: true), isTrue);
    expect(c.displayedPage, 3);
  });

  test('用户手动翻页后恢复自动跟随', () {
    final c = make(pageCount: 200);
    c.attach();
    c.markUserDriven();
    expect(c.userDriven, isTrue);
    expect(c.turnTo(1), isFalse);

    c.resumeAutoFollow();
    expect(c.userDriven, isFalse);
    expect(c.turnTo(1), isTrue);
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · 第 3 步：**「用户滑过」不能永久锁死跟读**
  //
  // 真机症状（用户 12:12-12:13）：
  // ```
  // AF[跟读] ref=21/15 disp=21
  // AF[跟读] ref=22/1  disp=21   ← 朗读翻页，画面不动
  // AF[跟读] ref=23/1  disp=21   ← 还是不翻，而且【没有 AF[turnTo挡下]】
  // ```
  // 根因不在这一个类里（是页面侧 `_userScrolling` 先把整段跳过了），
  // 但**闸门这一层是"永久锁死"的一半**：`_userDriven` 一旦为真，
  // 只有两处显式指令（回到朗读位置 / 点句朗读）会清它，**没有自动过期**。
  //
  // 双条件解闸的语义（用户拍板）：
  // · 条件一：朗读**真的推进到新的一页**（与闸门当前页不同）
  // · 条件二：用户**停止滑动满 2 秒**
  // 两者都满足才解闸；只满足一个 → 不解，跟读只推进不抢画面。
  //
  // 本组用例钉住"闸门这一层"可被解闸 + 解闸后能翻；
  // 双条件的判定逻辑在页面侧（`_canAutoResumeFollow`），由设备用例覆盖。
  //
  // ## 为什么必须钉住"防抖"
  // 解闸条件里的"推进到新的一页"**同时就是防抖**：同一页内逐句推进时它不成立。
  // 配合 `turnTo` 自带的 `_turning` 闸门（一次落位没完成不发第二次），
  // 最终是**每页最多翻一次** —— 不会每句都滚。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ 用户滑过后解闸：能恢复跟读，但不能每句都滚', () {
    test('解闸后：跨页请求能翻（画面跟得上朗读）', () {
      final c = make(pageCount: 200);
      c.attach(initialPage: 21);
      c.markUserDriven();

      // 前置：滑过之后请求翻页被挡（这就是真机"画面卡住"的那一半）
      expect(c.turnTo(22), isFalse, reason: '前置：userDriven 必须挡下跟读');

      // 解闸（页面侧确认双条件都满足后调用）
      c.resumeAutoFollow();
      expect(c.turnTo(22), isTrue, reason: '★解闸后必须能翻到朗读所在的页');
      // ⚠️ 跨度 1 走**动画档**：`_displayedPage` 要等落位回调才更新
      // （这是刻意的设计 —— §4.58 要求用"动画落地后的"页码当当前页）。
      // 所以这里补一次落位，模拟动画结束。
      c.onPageSettled(22);
      expect(c.displayedPage, 22, reason: '落位后当前页必须跟到朗读页');
    });

    test('同页请求不发第二次（这就是"防每句都滚"）', () {
      final c = make(pageCount: 200);
      c.attach(initialPage: 21);
      var turns = 0;
      c.animateTo = (page, d) => turns++;
      c.jumpTo = (page) => turns++;

      // 同一页里连读 5 句：每一句都会请求"翻到第 22 页"
      c.resumeAutoFollow();
      for (var i = 0; i < 5; i++) {
        c.turnTo(22);
      }
      expect(turns, 1, reason: '★同一目标页只允许发一次翻页（否则每句都滚）');

      // 落位之后再请求同一页：应当直接归位、不再翻
      c.onPageSettled(22);
      expect(c.turnTo(22), isTrue, reason: '已在目标页：返回 true 但不算翻页');
      expect(turns, 1, reason: '★已在目标页不许再发翻页动作');
    });

    test('解闸不是"永久有效"：再次手动翻页仍会重新上锁', () {
      final c = make(pageCount: 200);
      c.attach(initialPage: 21);
      c.markUserDriven();
      c.resumeAutoFollow();
      expect(c.turnTo(22), isTrue);

      // 用户又滑了一次 → 必须重新挡住
      c.markUserDriven();
      expect(c.turnTo(30), isFalse,
          reason: '★再次手动翻页后必须重新锁住（否则用户看不完就被抢画面）');
    });

    test('★解闸之后不许再以 userDriven 为由挡下（防"两个都打"）', () {
      // 用户要求：解闸那一下打 `AF[自动解闸]`，**不能同时又打一条
      // `AF[turnTo挡下 原因=userDriven]`** —— 两条同时出现说明解闸判定没生效。
      //
      // 页面侧的挡下原因判定是：
      //   pageCount<=0 ? "pageCount<=0" : (userDriven ? "userDriven" : (turning ? "turning" : "未知"))
      // 所以这里用同一套顺序复现一遍，确认解闸后 userDriven 一定是 false。
      final c = make(pageCount: 200);
      c.attach(initialPage: 21);
      c.markUserDriven();
      expect(c.turnTo(30), isFalse);
      expect(c.userDriven, isTrue, reason: '前置：这一拍确实以 userDriven 挡下');

      c.resumeAutoFollow();
      expect(c.userDriven, isFalse,
          reason: '★解闸后 userDriven 必须为 false —— 否则挡下原因还会报 userDriven，'
              '与 AF[自动解闸] 同时出现');
      // 解闸后这一次成功，所以连"挡下"都不会发生
      expect(c.turnTo(30), isTrue);
    });
  });

  test('settleTimeout 兜底：落地回调不来也要放开闸门', () async {
    final c = PdfPageTurnController(
      pageCount: 20,
      animationDuration: const Duration(milliseconds: 5),
      settleTimeout: const Duration(milliseconds: 60),
    );
    c.scheduleAfterFrame = channel.immediateScheduler;
    c.jumpTo = (page) => channel.turns.add((page, true));
    c.animateTo = (page, _) => channel.turns.add((page, false));
    c.attach();
    c.onPageSettled(0);
    c.turnTo(1);
    expect(c.isTurning, isTrue);

    // 故意不调 onPageSettled，等兜底定时器
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.isTurning, isFalse,
        reason: '落地回调不来也不能永久卡住闸门');
    c.dispose();
  });

  test('pageCount 为 0：任何翻页都失败，不崩', () {
    final c = make(pageCount: 0);
    expect(c.turnTo(0), isFalse);
    expect(c.turnTo(5), isFalse);
  });

  // ---------- §4.100 任务 C 回归 ----------

  test('⚠️ 连点快进 20 次：翻页次数 ≪ 请求次数（闸门必须拦得住）', () {
    // 复现场景：用户连点「下一句」，每次推进都会请求翻页。
    // 历史 bug（v1.21.5 前）：阅读页的闸门 pageCount 恒 0，turnTo 全被
    // 静默吞掉，页面靠 ensureVisible 旁路乱滑；修好后连点必须被
    // 「已在目标页 / 上一次未落地」两道闸门拦下。
    final c = make(pageCount: 200);
    c.attach();
    c.onPageSettled(0);
    var requests = 0;
    var acted = 0;
    for (var i = 1; i <= 20; i++) {
      requests++;
      if (c.turnTo(i)) acted++;
      // 快进时推进循环可能回头请求「刚才那一页」（重复目标）
      c.turnTo(i);
    }
    // 相邻页动画：每次都要等落地才放开闸门，测试里不喂落地回调，
    // 所以第一次之后全被拦 —— 这正是「翻页次数远小于快进次数」的判据
    expect(acted, lessThan(requests ~/ 2),
        reason: '翻页动作($acted)必须远少于快进请求($requests)，不能 1:1');
    expect(channel.turns.length, lessThan(requests),
        reason: '真正发出的落位动作更少');
  });

  test('连点时喂入落地回调：每翻一页才允许下一页（不连翻）', () {
    final c = make(pageCount: 200);
    c.attach();
    c.onPageSettled(0);
    var acted = 0;
    for (var i = 1; i <= 20; i++) {
      if (c.turnTo(i)) acted++;
      // 模拟动画落地（onPageChanged 语义）
      c.onPageSettled(i);
    }
    expect(acted, 20, reason: '每次都落地时，请求都该被受理');
    expect(channel.turns.where((t) => t.$2).length, 0,
        reason: '相邻页（跨 1）不许走瞬时跳');
    expect(channel.turns.length, 20);
  });

  test('快进跨大跨度：瞬时落位一次到位（§4.90 的 jumpToPage 规则）', () {
    final c = make(pageCount: 319);
    c.attach();
    c.onPageSettled(0);
    // 一次请求跳到第 50 页：跨度 >2 → 瞬时
    expect(c.turnTo(50), isTrue);
    expect(c.displayedPage, 50, reason: '先记账：落地回调不来也不会重复翻');
    expect(channel.turns, hasLength(1), reason: '只发一次落位动作');
    expect(channel.turns.single, (50, true), reason: '必须是瞬时跳');

    // 记账后对同一目标的再次请求被「已在目标页」拦住
    //
    // ⚠️ v1.21.43 定稿：这条契约**回到原样**。
    // 中途曾"升级"成"`_jumpPending` 为真时同目标页也重发"，那是为了救
    // 「硬上限递归重试」；但那个方案会让**跟读每句都重发**（实测回归）。
    // 现在硬上限改成**直接重发 jump、不走递归**，于是重发条件可以
    // 安全地带上 `_turnTargetPage != target` 约束 —— 本条契约随之恢复。
    expect(c.turnTo(50), isTrue);
    expect(channel.turns, hasLength(1),
        reason: '同一目标页的重复请求必须被拦住（不许每句重发）');
  });

  test('⚠️ pageCount 可后置补设（真实链路：initState 时文档还没打开）', () {
    // v1.21.5 修的真实缺陷：阅读页 initState 构造闸门时只能给 pageCount=0，
    // 而文档要异步才打开 —— 若 pageCount 是 final，闸门永远吞请求，
    // 自动翻页整个失效（连点快进 20 次的实测：闸门一次都没响）。
    final c = PdfPageTurnController(
      pageCount: 0,
      animationDuration: const Duration(milliseconds: 10),
      settleTimeout: const Duration(milliseconds: 200),
    );
    c.scheduleAfterFrame = channel.immediateScheduler;
    c.jumpTo = (page) => channel.turns.add((page, true));
    c.animateTo = (page, _) => channel.turns.add((page, false));
    expect(c.turnTo(5), isFalse, reason: '页数还没填上：不敢瞎翻');

    c.attach(pageCount: 319, initialPage: 12);
    expect(c.displayedPage, 12, reason: 'attach 可按已有位置认下初始页');
    expect(c.turnTo(60), isTrue, reason: '补设页数后闸门恢复工作');
    expect(c.turnTo(61), isTrue);
    c.dispose();
  });

  // ──────────────────────────────────────────────────────────────────────
  // v1.21.43 · **turning 泄漏（真机卡 32 秒）** 回归
  //
  // 真机日志：
  // ```
  // 15:03:28  AF[跟读] ref=26/1  disp=25  turning=true
  // 15:03:35  AF[turnTo挡下 page=26 原因=turning]
  // 15:03:51  AF[跟读] ref=26/7  disp=25  turning=true
  // 15:04:00  ref=27/0  disp=25  turning=false   ← 32 秒
  // ```
  // 根因：旧 `turnTo` 的动画档每来一次请求就
  // `_settleTimer?.cancel(); _settleTimer = Timer(settleTimeout, …)` ——
  // **把 700ms 一直往后推**。跟读每句都来请求（且 `disp` 还没变），
  // 于是 32 秒里从没连续空过 700ms，**定时器一次都没响过**。
  // ──────────────────────────────────────────────────────────────────────

  group('⚠️ turning 泄漏（真机卡 32 秒的根因）', () {
    test('★反复请求不许把落位定时器推后（旧实现必红）', () async {
      // 用小超时跑得快，但**语义与 700ms 完全一样**
      final c = PdfPageTurnController(
        pageCount: 200,
        animationDuration: const Duration(milliseconds: 5),
        settleTimeout: const Duration(milliseconds: 120),
      );
      var turns = 0;
      c.scheduleAfterFrame = channel.immediateScheduler;
      c.animateTo = (page, _) => turns++;
      c.jumpTo = (page) => turns++;

      c.attach(initialPage: 25);
      expect(c.turnTo(26), isTrue);
      expect(c.isTurning, isTrue, reason: '前置：动画档要占住闸门');

      // ★模拟跟读：60ms 一次、连来 6 次（共 360ms > 120ms 超时 3 倍）
      //   旧实现每次都会 cancel + 重开 120ms → 360ms 内一次都不会响
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        c.turnTo(26); // 每句都会来请求（disp 还没变，所以仍走动画档前的让位）
      }

      // 再等过一个超时窗口：**定时器必须已经响过**
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // ignore: avoid_print
      print('DEVICE_VERIFY[turning-leak] 反复请求 6 次后 isTurning=${c.isTurning} '
          'turns=$turns（旧实现：isTurning 恒 true、turns 恒 1）');
      expect(c.isTurning, isFalse,
          reason: '★这才是本 bug 的核心：反复请求不得把落位定时器无限推后');
      // 注：`turns > 1` 是**修复生效的正面证据** —— 定时器响了、闸门放开了，
      // 后续请求才会再发一次。旧实现里定时器从不响，`turns` 会停在 1
      // 且 `isTurning` 永久为 true（真机卡 32 秒就是这个）。
      expect(turns, greaterThan(1),
          reason: '★定时器响过 → 闸门放开过 → 后续请求能再发（旧实现恒为 1）');
    });

    test('★硬上限：落位回调永不来时，超过上限强制放开并重试一次', () async {
      final c = PdfPageTurnController(
        pageCount: 200,
        animationDuration: const Duration(milliseconds: 5),
        settleTimeout: const Duration(milliseconds: 50),
        turnHardCeiling: const Duration(milliseconds: 150),
      );
      var turns = 0;
      c.scheduleAfterFrame = channel.immediateScheduler;
      c.animateTo = (page, _) => turns++; // ★故意不调 onPageSettled = 回调永不来
      c.jumpTo = (page) => turns++;

      c.attach(initialPage: 25);
      c.turnTo(26);
      expect(turns, 1);

      // 过一个 settleTimeout（50ms）→ 定时器放开 _turning，但 disp 仍是 25
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // 再来请求：因为 _turning 已被定时器放开，会**再发一次**动作
      c.turnTo(26);
      expect(turns, 2, reason: '定时器放开后允许再发（这是既有行为）');
      // ignore: avoid_print
      print('DEVICE_VERIFY[turning-hard] 硬上限=${c.turnHardCeiling.inMilliseconds}ms '
          'turns=$turns disp=${c.displayedPage}');
      expect(c.displayedPage, 25, reason: '落位回调不来 → disp 不会变（所以需要硬上限）');
    });

    test('★jump 分支：同目标页被拦住；目标页变了才重发', () {
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(0);

      // 跳到第 50 页（跨度 >2 → jump，预写 disp=50，_jumpPending=true）
      expect(c.turnTo(50), isTrue);
      expect(channel.turns, hasLength(1));

      // ① 同一目标页：**必须被拦住**（不许每句重发 —— 这是回归防线）
      expect(c.turnTo(50), isTrue);
      expect(channel.turns, hasLength(1),
          reason: '★同目标页只发一次（`_turnTargetPage != target` 约束）');
      expect(c.turnTo(50), isTrue);
      expect(channel.turns, hasLength(1), reason: '★再来一次仍被拦');

      // ② 目标页变了 → 必须真发一次（不能因为"预写过"就假报已到）
      expect(c.turnTo(60), isTrue);
      expect(channel.turns, hasLength(2));
      expect(channel.turns.last, (60, true));

      // ③ 确认落位后，同目标页仍被拦
      c.onRevealFinished(60);
      expect(c.turnTo(60), isTrue);
      expect(channel.turns, hasLength(2));
    });

    test('★★连续多句 + reveal 一直不来：只该被硬上限重发，不被每句触发', () async {
      // 这条是"每句重发"回归的专门防线。
      // 场景：jump 预写后落位回调**永不到来**，跟读一句接一句地请求同一目标页。
      // 期望：jumps 只在「首次」和「每次硬上限」增长，**不随句数增长**。
      final c = PdfPageTurnController(
        pageCount: 319,
        animateLimit: 2,
        animationDuration: const Duration(milliseconds: 5),
        settleTimeout: const Duration(milliseconds: 40),
        // ⚠️ 窗口给大一点，让下面的循环**明显短于**它。
        // 实测踩过两次边界：窗口 100ms + 循环 100ms → 循环最后一拍正好
        // 落在窗口上、硬上限**合法触发**，用例把正常行为误判成回归。
        // 现在：窗口 500ms / 循环 5×20ms=100ms（占 20%），余量充足。
        turnHardCeiling: const Duration(milliseconds: 500),
      );
      var jumps = 0;
      c.scheduleAfterFrame = channel.immediateScheduler;
      c.jumpTo = (page) => jumps++;   // ★故意不调 onPageSettled / onRevealFinished
      c.animateTo = (page, _) {};

      c.attach(initialPage: 0);
      expect(c.turnTo(10), isTrue);
      expect(jumps, 1, reason: '首次 jump');

      // ★连续 5 句、每句 20ms（共 100ms，只占 500ms 窗口的 20% → 远不到点）
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        c.turnTo(10);
      }
      // ignore: avoid_print
      print('DEVICE_VERIFY[same-target] 连 5 句 + reveal 不来 → jumps=$jumps '
          'isTurning=${c.isTurning} disp=${c.displayedPage}');
      expect(jumps, 1,
          reason: '★这 5 句都在硬上限窗口内 → **一次都不该重发**'
              '（旧回归：jumps 会涨到 5~6）');

      // ★再跨过一个硬上限窗口 → 硬上限**直接重发**一次
      await Future<void>.delayed(const Duration(milliseconds: 650));
      c.turnTo(10);
      expect(jumps, 2, reason: '★硬上限到点 → 直接重发一次');
      // 重发之后再来一句：仍在窗口内 → 不涨
      c.turnTo(10);
      expect(jumps, 2, reason: '★重发后同目标页继续被拦');
    });

    test('★动画档卡住：硬上限也必须触发（`_turning` 那一半判据）', () async {
      // 与 jump 那条互为补集，合起来钉住 `(_jumpPending || _turning)` 的**两半**：
      // · jump 档：`_jumpPending=true`、`_turning=false` → 靠 `_jumpPending` 触发
      // · 动画档：`_jumpPending=false`、`_turning=true` → 靠 `_turning` 触发
      // 只判其中一个 → 另一半永远不触发、那条路死锁（正是要治的场景）。
      final c = PdfPageTurnController(
        pageCount: 319,
        animateLimit: 2,
        animationDuration: const Duration(milliseconds: 5),
        settleTimeout: const Duration(milliseconds: 200), // 故意长：先不让它兜底
        turnHardCeiling: const Duration(milliseconds: 100),
      );
      var animates = 0;
      var jumps = 0;
      c.scheduleAfterFrame = channel.immediateScheduler;
      c.animateTo = (page, _) => animates++;  // ★故意不调 onPageSettled
      c.jumpTo = (page) => jumps++;

      c.attach(initialPage: 0);
      // 跨度 1 → 动画档：`_turning=true`、`_jumpPending=false`、记起点
      expect(c.turnTo(1), isTrue);
      expect(c.isTurning, isTrue);
      expect(animates, 1);

      // 过一个硬上限窗口（100ms）后再请求：
      //   · 若判据漏了 `_turning` 这一半 → 这里什么都不做、`animates` 停在 1（死锁）
      //   · 判据正确 → 硬上限直接重发，**且走动画通道**（当前正有动画在下发）
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(c.turnTo(1), isTrue);
      // ignore: avoid_print
      print('DEVICE_VERIFY[turning-hard-anim] animates=$animates jumps=$jumps '
          'isTurning=${c.isTurning} disp=${c.displayedPage}');
      expect(animates, 2,
          reason: '★动画档卡住时硬上限必须触发，且重发**沿用动画通道**');
      expect(jumps, 0, reason: '不该把重发丢给瞬时跳通道（会与在飞的动画打架）');
    });

    test('★真落位 vs 已请求翻页：两个确认点各自打 AF[真落位]', () {
      // 语义区分（用户拍板）：
      // · "已请求翻页" = `turnTo` 返回 true（跳已发出，不代表到位）
      // · "真落位"     = 页面真的到位（回调确认）
      // 本用例只验**闸门侧**两个确认点都会把 `_displayedPage` 真的写成目标页；
      // 日志文案由下面的打印体现（CrashLog → 内存 recent）。
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(0);

      // ① 落位回调确认点：jump 预写 10 → 落位回调报 10 → disp 确认
      c.turnTo(10);
      expect(c.displayedPage, 10, reason: 'jump 预写（此时只是"已请求"）');
      c.onPageSettled(10); // ← 真落位
      expect(c.displayedPage, 10);

      // ② reveal 结束确认点：动画档 → reveal 结束报同一页 → 清账
      c.turnTo(11); // 跨度 1 → 动画档，此时 disp 仍是 10（"已请求"）
      expect(c.displayedPage, 10, reason: '动画档不预写：这才是"已请求"的本意');
      expect(c.isTurning, isTrue);
      c.onRevealFinished(11); // ← 真落位（但仍按"放弃等待"清账）
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-settle] ①回调后 disp=${c.displayedPage} '
          '②reveal 后 turning=${c.isTurning}');
      expect(c.isTurning, isFalse, reason: 'reveal 结束必须放闸门');
    });

    test('★reveal 不来：只有"已请求翻页"、没有"真落位"（假已翻的样子）', () {
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(0);

      // jump 预写：调用方拿到 true（= 已请求翻页），但**没有任何回调**
      expect(c.turnTo(10), isTrue);
      expect(c.displayedPage, 10, reason: '预写的页码 —— 看起来"到了"，其实是假的');
      // 不复现 `onPageSettled` / `onRevealFinished` → 永远拿不到"真落位"
      // ignore: avoid_print
      print('DEVICE_VERIFY[real-settle] reveal 不来：disp=${c.displayedPage} '
          '（预写值）jumpPending=${c.debugJumpPendingForTest} '
          'turnStartedAt=${c.debugTurnStartedAtForTest != null}');
      expect(c.debugJumpPendingForTest, isTrue,
          reason: '★没有真落位 → 仍处于"等确认"状态（这就是假已翻的判据）');
      expect(c.debugTurnStartedAtForTest, isNotNull,
          reason: '★等确认的起点还在 → 硬上限能兜到');
    });

    test('★硬上限重发后能收干净：reveal 回调来了 → 闸门放开、不再重发', () {
      // 补上我上一轮漏掉的"后半段"：重发之后**能收干净**
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(0);

      expect(c.turnTo(10), isTrue);          // jump 预写
      expect(channel.turns, hasLength(1));

      // 收敛链结束 → 清账
      c.onRevealFinished(10);
      expect(c.isTurning, isFalse, reason: 'reveal 结束必须放开闸门');
      // 之后再请求同一页：不再发动作
      expect(c.turnTo(10), isTrue);
      expect(channel.turns, hasLength(1),
          reason: '★收干净之后再请求同目标页 → 不发动作');
    });

    test('★硬上限：jump 预写未落地 → 超时后**真重发 jump**（不是假已翻）', () async {
      // 这是"假已翻"最容易复发的场景：`target == _displayedPage`（jump 预写了，
      // 但落位动作没确认）。硬上限若清掉 `_jumpPending`，递归就会命中
      // 「已在目标页」→ 返回 true 但页面没动。
      final c = PdfPageTurnController(
        pageCount: 319,
        animateLimit: 2,
        animationDuration: const Duration(milliseconds: 5),
        settleTimeout: const Duration(milliseconds: 40),
        turnHardCeiling: const Duration(milliseconds: 60),
      );
      var jumps = 0;
      var animates = 0;
      c.scheduleAfterFrame = channel.immediateScheduler;
      c.jumpTo = (page) => jumps++;      // ★故意不调 onPageSettled/onRevealFinished
      c.animateTo = (page, _) => animates++;

      c.attach(initialPage: 0);
      // 跨度 10 > 2 → jump 分支：预写 disp=10、置 _jumpPending、发 1 次 jump
      expect(c.turnTo(10), isTrue);
      expect(jumps, 1);
      expect(c.displayedPage, 10, reason: 'jump 预写');

      // 过一个硬上限窗口后再请求（模拟跟读下一句）
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.turnTo(10), isTrue);
      // ignore: avoid_print
      print('DEVICE_VERIFY[turning-hard-retry] jumps=$jumps animates=$animates '
          'disp=${c.displayedPage} isTurning=${c.isTurning}');
      expect(jumps, 2,
          reason: '★硬上限必须**直接重发 jump**（不是假已翻、也不是走递归）；'
              '若只清标记不重发，这里会停在 1');
      expect(animates, 0, reason: '目标页相同 → 不该走动画档');
    });

    test('★onRevealFinished 解锁：回调不来时靠它放闸门（第 4 个出口）', () {
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(0);

      c.turnTo(50);
      expect(c.isTurning, isFalse, reason: 'jump 不算「正在翻页」（既有契约）');

      // 收敛链结束（目标页已可见 / 放弃）→ 清掉"预写未确认"
      c.onRevealFinished(50);
      // 之后对同一页的请求：走「已在目标页」，不再重发
      expect(c.turnTo(50), isTrue);
      expect(channel.turns, hasLength(1));
    });

    test('★过期落位报告：只丢"回退"，前进一律接受（不许反杀用户滑动）', () {
      final c = make(pageCount: 319);
      c.attach();
      c.onPageSettled(100);
      expect(c.displayedPage, 100);

      // 造"落位进行中"：101 - 100 = 1 → 动画档，占住闸门
      c.turnTo(101);
      expect(c.isTurning, isTrue, reason: '前置：动画档要占住闸门');
      expect(c.displayedPage, 100,
          reason: '前置：动画档**不预写**页码（只有 jump 分支才预写）');

      // ① 更靠前的报告（回退）→ 只放闸门、**不回写页码**
      final before = c.displayedPage;
      c.onPageSettled(before - 1);
      // ignore: avoid_print
      print('DEVICE_VERIFY[stale-settle] 回退报告 ${before - 1} → '
          'disp=${c.displayedPage} turning=${c.isTurning}');
      expect(c.displayedPage, before,
          reason: '★落位进行中的回退报告不许把页码倒退（治 settled/disp 抖动）');
      expect(c.isTurning, isFalse, reason: '但闸门要放开');

      // ② 用户往下滑：更靠后的报告必须被接受（"不许反杀用户滑动"）
      c.onPageSettled(before + 5);
      expect(c.displayedPage, before + 5,
          reason: '★前进一律接受：用户滑到后面必须跟（这才是正常场景）');
    });
  });

  test('dispose 之后不再持有控制器', () {
    final c = make();
    c.attach();
    c.dispose();
    expect(c.turnTo(1), isTrue, reason: 'controller 没了就只记账，不崩');
  });
}
