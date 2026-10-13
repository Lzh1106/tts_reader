import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/crash_log.dart';

/// 自动翻页闸门。
///
/// ## 为什么把它单独抽出来
///
/// 「朗读推进 → 页面跟着翻」踩过两次大坑，都是**闸门没做对**：
///
/// - HANDOFF §4.58：判定当前页必须用**动画落地后的**页码。读 `PageController.page`
///   会在动画途中就拿到新页，于是「刚翻过去又被判定为读完」→ 连着往后翻；
/// - HANDOFF §4.90：跨度大时用逐页动画会**逐页渲染**，
///   从第 1 页跳到第 148 页看着就是「疯狂快速翻页」。跨度 > 2 页必须瞬时落位。
///   而瞬时落位会**同步**触发页码回调 → 里面 setState → 在 build 期就是
///   `setState() called during build`，所以落位与 setState 都要放到帧后。
///
/// 这三条都是纯状态逻辑，塞在 Widget 里既难测又容易被后来的改动碰坏。
/// 抽成控制器后，用注入的「落位动作」就能把三条钉死。
///
/// ## 与具体控件的解耦
///
/// 本页用的是**纵向连续滚动**（`ListView`），不是 `PageView`，
/// 所以没有 `jumpToPage`。但闸门要管的规则完全一样 —— 于是把「怎么落位」
/// 抽象成回调 [jumpTo] / [animateTo]，控件换掉也不用动这里。
class PdfPageTurnController {
  /// 设备用例用：**当前挂载中**的阅读页所持有的闸门实例
  ///
  /// 为什么需要全局引用：真机那条出问题的路径是「**用户手动滑动过** → 切书 →
  /// 点继续」，而 `_userDriven` 只有闸门自己知道。设备用例要复现它就必须拿到
  /// 阅读页里的那个实例（它是私有字段）。
  ///
  /// ⚠️ 只在**真实阅读页** `initState`/`dispose` 里赋值/清空；纯逻辑单测
  /// 自己 `make()` 的实例不会写它（避免把测试之间串起来）。
  static PdfPageTurnController? debugActiveForTest;

  PdfPageTurnController({
    required this.pageCount,
    this.animateLimit = 2,
    this.animationDuration = const Duration(milliseconds: 260),
    this.settleTimeout = const Duration(milliseconds: 700),
    this.turnHardCeiling = const Duration(seconds: 3),
  });

  /// 总页数（用于夹取；PDF 一章即一页）
  ///
  /// ⚠️ v1.21.5 改为**可后置赋值**：阅读页的 `PdfPageTurnController` 在
  /// `initState` 时就构造（那时文档还没打开），页数要等 `onDocumentLoaded`
  /// 之后才能填。原来是 `final`，页面只能先给 0 —— 而 `turnTo` 开头
  /// `if (pageCount <= 0) return false;` **直接吞掉每一次翻页请求**，
  /// 于是自动翻页整个不工作（实测连点快进 20 次：闸门探针一次都没响，
  /// 页面却照样在滑 —— 滑页走的是 `onSentenceChanged → ensureVisible`
  /// 那条旁路。§4.100 任务 C 的根因）。
  int pageCount;

  /// 跨度**超过**这个值就瞬时落位，不做逐页动画（HANDOFF §4.90）
  final int animateLimit;

  final Duration animationDuration;

  /// 落位超时兜底：落地回调万一不来也不能永久卡住闸门
  final Duration settleTimeout;

  /// **落位硬上限**（v1.21.43 · 治 turning 泄漏）
  ///
  /// 超过这个时长仍未确认落位 → 强制放开闸门并**重试一次**。
  ///
  /// 为什么一个 [settleTimeout] 不够（真机日志为证）：
  /// ```
  /// 15:03:28  AF[跟读] ref=26/1  disp=25  turning=true
  /// 15:03:35  AF[turnTo挡下 page=26 原因=turning]
  /// 15:03:51  AF[跟读] ref=26/7  disp=25  turning=true
  /// 15:04:00  ref=27/0  disp=25  turning=false   ← 32 秒
  /// ```
  /// `settleTimeout`（700ms）那个定时器**每句都被 `cancel() + 重开`**
  /// （见 [turnTo] 旧实现），32 秒里从没连续空过 700ms → **一次都没响过**。
  /// 而且 jump 分支（跨度 > [animateLimit]）**压根没有定时器**。
  ///
  /// ⚠️ **本上限是 jump 分支的必要条件**：jump 分支靠瞬时落位、没有 `_settleTimer`，
  /// 一旦落位回调不来（`_pageAtOffset` 返回 null 或 `page == _lastSettledPage`，
  /// 见 `pdf_reading_page._scheduleSettle`），**只有本上限 + [onRevealFinished] 能放出闸门**。
  /// 回退本段时必须连它们一起回退，否则大跨度翻页会死锁。
  final Duration turnHardCeiling;

  /// 瞬时落位到某一页（0 起）
  ///
  /// 交付前会被包一层「帧后执行」—— 落位会同步触发落地回调，
  /// 而那里往往要 setState。
  void Function(int pageIndex)? jumpTo;

  /// 带动画落位到某一页（0 起）
  void Function(int pageIndex, Duration duration)? animateTo;

  /// 帧后回调的调度器（测试可替换成同步执行）
  void Function(VoidCallback) scheduleAfterFrame =
      (callback) => WidgetsBinding.instance.addPostFrameCallback((_) => callback());

  /// **落地后的**当前页（唯一可信的「当前页」，HANDOFF §4.58）
  int _displayedPage = 0;

  /// 一次落位还没完成
  bool _turning = false;
  Timer? _settleTimer;

  /// 落位进行中「最新一次请求的目标页」（每句都可能来请求，只更新它、不续期定时器）
  int? _turnTargetPage;

  /// 本次落位**真正开始**的时刻。
  ///
  /// ⚠️ 跟读期间每句都会重试 `turnTo`，所以它**绝不能被重试覆盖** ——
  /// 否则硬上限也永远算不到点（那正是 700ms 定时器失效的同一种病）。
  /// 只有"开始一次新的落位"或"确认落位"时才重置。
  DateTime? _turnStartedAt;

  /// jump 分支已经**预写** `_displayedPage` 但还没确认落位（v1.21.43 · 改动 4'）
  ///
  /// ## 为什么必须有它
  ///
  /// jump 分支会**先记账再跳**（`_displayedPage = target`）—— 这是**故意的**：
  /// 高亮就是按它画的（`pdf_reading_page._highlightFor`），不预写会让
  /// "页面已跳过去、高亮还停在旧页"（就是用户报的那个症状）。
  ///
  /// 但预写带来一个新问题：**翻页失败后的重试会命中「已经在目标页」而假报成功**
  /// （`target == _displayedPage` → `return true`，可页面根本没动）。
  /// 这个标记把"预写"与"真落位"区分开。
  ///
  /// ## 生命周期（单一写入点，5 个清除出口）
  ///
  /// 置 `true`：**仅** [turnTo] 的 jump 分支预写 `_displayedPage` 时。
  /// 置 `false`：① [onPageSettled] 落位确认（含过期报告分支）
  ///             ② [onRevealFinished] 收敛链结束
  ///             ③ [resetForDocument] 换书复位
  ///             ④ [attach] 切书 / 初始页
  ///             ⑤ 过期落位报告（`onPageSettled` 里那条回退分支）
  ///             ⑥ jump 分支发现"没有落位通道"时（`jumpTo == null`）
  ///
  /// ⚠️ **硬上限强制放开时【不清】它** —— 硬上限要兜的场景恰恰是
  /// `target == _displayedPage`（预写了没落地）；清了就会让"仍未确认"这个
  /// 事实消失，后续请求会走「已在目标页」而不再重发。
  /// 硬上限现在**直接重发 jump**（不走递归），因此它只需把本标记**保持为真**。
  bool _jumpPending = false;

  /// 用户手动翻过页：暂停自动翻页（对齐 §4.64 的自动定位分工）
  bool _userDriven = false;

  int get displayedPage => _displayedPage;

  bool get isTurning => _turning;

  bool get userDriven => _userDriven;

  /// 仅供测试诊断：`_jumpPending` / `_turnStartedAt` 的当前值
  @visibleForTesting
  bool get debugJumpPendingForTest => _jumpPending;

  @visibleForTesting
  DateTime? get debugTurnStartedAtForTest => _turnStartedAt;

  /// 设备用例用：把「用户手动翻过页」置真（真机上由手指拖动触发 [markUserDriven]）
  ///
  /// 用例要用它复现真机那条路径：**用户滑动过页面 → 切书 → 点继续**。
  /// 没有这个钩子就只能去模拟真实手指拖动（在设备用例里很难稳定复现）。
  @visibleForTesting
  set userDrivenForTest(bool value) => _userDriven = value;

  int get _lastIndex => pageCount <= 0 ? 0 : pageCount - 1;

  /// 只记录初始页（不再需要 PageController）
  ///
  /// [pageCount] 允许文档打开后再补设（见字段说明，§4.100 任务 C）：
  /// 传 null 表示不改。补设时初始页一并夹取。
  void attach({int? initialPage, int? pageCount}) {
    if (pageCount != null) this.pageCount = pageCount;
    if (initialPage != null) {
      _displayedPage = initialPage.clamp(0, _lastIndex);
    }
    // 切书 / 认初始页 = 放弃等待上一次落位确认
    _clearTurnAccounting();
  }

  /// 清掉「一次落位」的全部账（**唯一的地方**，避免各处漏清）
  ///
  /// 调用它的都是"放弃等待落位确认"的时刻：切书、换书复位、
  /// 落位真的确认了、reveal 收敛链结束、硬上限强制放开。
  void _clearTurnAccounting() {
    _turning = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    _turnStartedAt = null;
    _turnTargetPage = null;
    _jumpPending = false;
  }

  /// **换书复位**（v1.21.43 · P0-2）
  ///
  /// ## 为什么必须有这个方法（真机症状：切书后点「继续」高亮不显示 / 跳错页）
  ///
  /// 闸门有**三个跨书存活的状态**，而它们全都只在"同一本书内"才有意义：
  /// · `_displayedPage` —— 上一本书的页号（新书写页数还不一样）；
  /// · `_turning` —— 上一次落位还没完成（换书那一刻它多半就是 true）；
  /// · `_userDriven` —— 用户手动滑过页。**只有三处会清它**
  ///   （"回到朗读位置" / 重新点句朗读），**换书路径一处都没有**。
  ///
  /// 于是用户一旦滑动过页面再切书，后续每一次跟读都被
  /// `if (_userDriven && !force) return false;` **静默挡下**：
  /// `onSentenceChanged` 又把返回值丢掉了 → **没人重试** →
  /// 表现就是用户报的「不显示高亮、不跳转朗读页」。
  ///
  /// 所以换书必须显式复位这三样，并顺手清掉落位兜底定时器
  /// （否则旧书的定时器会在新书上把 `_turning` 又放掉）。
  void resetForDocument({int? pageCount, int? initialPage}) {
    if (pageCount != null) this.pageCount = pageCount;
    _displayedPage = (initialPage ?? 0).clamp(0, _lastIndex);
    _turning = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    _userDriven = false; // ★关键：换书后必须重新允许自动跟读
    // 换书 = 放弃等待上一次落位确认（_jumpPending 必须一起清，否则新书第一次
    // 落在同一页号时会被误判成"预写未确认"而重复发 jump）
    _clearTurnAccounting();
  }

  /// 落位完成后由界面调用：**这是唯一更新「当前页」的地方**
  ///
  /// 纵向滚动时它由「滚动停下来」推出（见阅读页的实现），
  /// 而不是由 `PageView.onPageChanged` 直接给。
  void onPageSettled(int pageIndex) {
    final p = pageIndex.clamp(0, _lastIndex);
    // ★只有「落位进行中、且报告的是**更靠前**的页」才算过期报告（回退）。
    //
    // 为什么不能写成 `p != _displayedPage` 就丢：那会**反杀用户滑动** ——
    // `disp=26`（jump 预写）→ 用户手动滑到 27 → `onPageSettled(27)` 到达 →
    // 27 != 26 被判过期 → 不回写 → **高亮停在 26，用户操作丢了**。
    //
    // 回退报告只可能来自"被打断的旧落位"，丢掉它是对的；
    // **前进一律接受**（那多半就是用户往下滑）。
    final bool staleBackReport = _turning && p < _displayedPage;
    if (staleBackReport) {
      CrashLog.mark('AF[落位过期报告] 报=$p 现=$_displayedPage '
          '（更靠前的回退报告 → 只放闸门、不回写）');
    } else {
      _displayedPage = p;
      // ★ `AF[真落位]` —— **页面真的到位了**（落位确认点之一）。
      //
      // 与 `AF[自动解闸] … 已请求翻页` 严格区分：
      // · "已请求翻页" = `turnTo` 返回 true（**跳已发出**，不代表到位）；
      // · "真落位"     = 画面回调确认**页码真的变成了这一页**。
      // 排查"假已翻"就看这两条：只有"已请求"、没有"真落位" = 没到位。
      CrashLog.mark('AF[真落位] page=$p 来源=落位回调');
    }
    // ⚠️ 已知局限（本轮不动，仅标记）：`_turning = false` 是无条件清的。
    // 若"新 jump 在飞"与"旧落位报告晚到"同时发生，会把新 jump 的 `_turning`
    // 也放掉。罕见，且后果只是"允许下一次翻页"，不会死锁。
    _turning = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    _turnStartedAt = null;
    _turnTargetPage = null;
    _jumpPending = false;
  }

  /// **收敛链结束**（v1.21.43 · 改动 6）：reveal 把目标页带进视野了，或重试上限放弃
  ///
  /// ## 为什么必须有这个第四出口
  ///
  /// `_jumpPending` 若只靠 [onPageSettled] 清，而后者依赖 `_pageAtOffset`
  /// 能推出页码（页高没量到就返回 `null`，见 `pdf_reading_page._scheduleSettle`），
  /// 就会**永久为真** → 硬上限每 3 秒空转重发一次 jump。
  ///
  /// reveal 链**自己知道什么时候结束**（`_isPageIndexVisible` 为真，或
  /// `attempt >= 24` 放弃），这是唯一可靠的第 4 个出口。
  ///
  /// 页面侧调用点：`_revealToPageIndex` 的两个出口各一次。
  ///
  /// ⚠️ **不做"目标页必须等于 `_displayedPage`"的早退**：
  /// reveal 结束代表**动作结束**，与"页码是否已变"无关。若早退，
  /// "reveal 目标 25、期间硬上限已把 disp 推到 26、reveal 结束报 25"
  /// 这种情形会把结束信号吃掉，`_jumpPending` 就永远清不掉。
  void onRevealFinished(int pageIndex) {
    if (!_jumpPending && !_turning) return; // 本来就没在等：无需清理
    // ★ `AF[真落位]` —— **落位确认点之二**：reveal 收敛链结束。
    //
    // 两个确认点的分工：
    // · `onPageSettled`：滚动停下来反推出的页码（纵向滚动的常规路径）；
    // · `onRevealFinished`：reveal 链自己知道"目标页到了 / 放弃重试了" ——
    //   这是**唯一不依赖 `_pageAtOffset` 能推出页码**的确认点
    //   （页高没量到时 `onPageSettled` 不会被触发，只有它能兜）。
    if (pageIndex == _displayedPage) {
      CrashLog.mark('AF[真落位] page=$pageIndex 来源=reveal结束');
    } else {
      CrashLog.mark('AF[reveal结束] 目标=$pageIndex 现=$_displayedPage '
          '（页码已变，仍按"放弃等待确认"清理；不计为真落位）');
    }
    _clearTurnAccounting();
  }

  /// 用户手动翻页 / 滑动：暂停自动翻页
  void markUserDriven() {
    _userDriven = true;
  }

  /// 恢复自动翻页（用户点了「回到朗读位置」/ 重新点句朗读）
  void resumeAutoFollow() {
    _userDriven = false;
  }

  /// 请求翻到 [pageIndex]（0 起）。
  ///
  /// 返回 true 表示**发出了**一次翻页（或本来就在那一页），false 表示被闸门挡下。
  bool turnTo(int pageIndex, {bool force = false}) {
    if (pageCount <= 0) return false;
    final target = pageIndex.clamp(0, _lastIndex);

    // ★★ 改动 2：**硬上限**（必须排在所有"让位"判断之前）
    //
    // 超过 [turnHardCeiling] 仍未确认落位 → 强制放开闸门并**递归重试一次**。
    // 它是 jump 分支的必要条件（jump 没有 `_settleTimer`），
    // 也是本文件里唯一"不依赖任何回调"的出口。
    //
    // ⚠️ 递归用 `force: false` 而**不是** `force: true`：
    //   · `force: true` 会让 `_jumpPending && !force` 恒为 false →
    //     递归命中「已经在目标页」→ **返回 true 但页面没动 = 假已翻**
    //     （硬上限本来是兜"回调不来"，结果兜完还是假已翻，等于没兜）；
    //   · `force: true` 还会连 `_userDriven` 那道闸一起绕过 →
    //     在用户正手动翻页时强推画面。
    //   `force: false` 两个问题都没有：`_jumpPending` 为真时会**真的重发 jump**，
    //   且用户滑过时 `:用户闸门` 照常挡下（硬上限不强推，语义更对）。
    final started = _turnStartedAt;
    // ⚠️ 条件用 `_jumpPending` **而不是** `_turning`：
    // jump 分支按既有契约不算"正在翻页"（`_turning` 保持 false），
    // 若这里要求 `_turning`，则**"jump 预写了却一直没确认"这种最需要兜底的
    // 情形反而永远不触发硬上限**（实测：jumps 停在 1、isTurning 一直 false）。
    // 所以判据是"**还有一次落位在等确认**" = `_jumpPending || _turning`。
    if (started != null &&
        (_jumpPending || _turning) &&
        DateTime.now().difference(started) >= turnHardCeiling) {
      // ★★ 直接重发 jump，**不走递归**（v1.21.43 定稿）
      //
      // 为什么不能递归 `return turnTo(retryTarget)`：
      //   · 递归会先命中「已经在目标页」，再靠 `_jumpPending` 分支重发；
      //     而那个分支**必然要带 `_turnTargetPage != target` 约束**
      //     （否则跟读每句都重发 —— 实测回归）。
      //   · 两个约束互相打架：硬上限需要"无条件重发"，跟读需要"有条件重发"。
      //     → 一条路走不出来，只能**各走各的**：跟读走 `:334` 的条件分支，
      //       硬上限走这里直接重发。
      //   · 直接重发还顺带消掉了"递归里 target == disp 假已翻"那个老问题。
      // `_turnTargetPage` **保留**（下一次硬上限还要用它取目标页）。
      final int retryTarget = _turnTargetPage ?? target;
      CrashLog.mark('AF[turnTo硬超时] 第 $_displayedPage 页落位超过 '
          '${turnHardCeiling.inSeconds} 秒未确认 → 沿原路重发第 $retryTarget 页');
      _turning = false;
      _settleTimer?.cancel();
      _settleTimer = null;
      _turnStartedAt = null; // 重发后会重新起算 → 每 3 秒最多一次

      // ★★ 分派规则：**按"卡住的那条路"重发**（不是"优先动画"、也不是硬编码 jump）
      //
      // 两条路的账完全不一样，混用会互相打架（两种错法都实测踩过）：
      // · jump 档：`_jumpPending=true` / `_turning=false`，账是 `_displayedPage` 预写；
      // · 动画档：`_jumpPending=false` / `_turning=true`，账是 `_turning` + `_settleTimer`。
      final bool pendingJump = _jumpPending;
      final bool pendingAnim = !_jumpPending && _turning;
      final action = jumpTo;

      if (pendingJump) {
        // —— jump 卡住：重发 jump（顺手再预写一次 disp）——
        _displayedPage = retryTarget;
        _jumpPending = true;
        if (action != null) scheduleAfterFrame(() => action(retryTarget));
      } else if (pendingAnim) {
        // —— 动画卡住：重发动画，并**按动画档原时序重开 `_settleTimer`** ——
        // （重开是必要的：上面刚把它 cancel 了，否则动画档就永久没有兜底定时器）
        final anim = animateTo;
        if (anim != null) {
          _turning = true;
          _turnTargetPage = retryTarget;
          _turnStartedAt = DateTime.now();
          _settleTimer?.cancel();
          _settleTimer = Timer(settleTimeout, () {
            _turning = false;
            _turnStartedAt = null;
          });
          scheduleAfterFrame(() => anim(retryTarget, animationDuration));
        } else {
          // 没有动画通道：退回瞬时跳（至少把画面带过去）
          _displayedPage = retryTarget;
          _jumpPending = true;
          if (action != null) scheduleAfterFrame(() => action(retryTarget));
        }
      }
      return true;
    }

    // 用户手动翻页期间不自动翻（force 用于「回到朗读位置」这类显式指令）
    if (_userDriven && !force) return false;

    // 已经在目标页：**要区分"真到了"与"jump 预写的"**
    if (target == _displayedPage) {
      if (_jumpPending && !force && _turnTargetPage != target) {
        // 预写的、还没真到，**且请求的是另一个目标页** → 重发一次落位。
        //
        // ⚠️ `_turnTargetPage != target` **不是可有可无的补丁，是必要约束**：
        // `target == _displayedPage` 有两种含义 ——
        //   (a) 预写未确认 → 需要重发；
        //   (b) 本页的 jump 已经重发过、正在等确认 → **不能再发**。
        // 只看 `_jumpPending` 分不开这两者，于是**跟读每来一句都会重发一次**
        // （实测回归：`jumps` 随句数线性增长）。`_turnTargetPage` 就是用来
        // 区分"这一页的 pending"与"上一页的 pending"的。
        // 硬上限那条路**不走这里**（它直接重发，见上），所以不受本约束影响。
        _turning = true;
        _turnStartedAt ??= DateTime.now();
        _turnTargetPage = target;
        final retryAction = jumpTo;
        if (retryAction != null) {
          CrashLog.mark('AF[turnTo重发] 第 $target 页（预写未确认且目标已变）');
          scheduleAfterFrame(() => retryAction(target));
        }
        return true;
      }
      _turning = false;
      return true;
    }

    // ★★ 改动 1：落位进行中 —— **只更新目标页，绝不 cancel + 重开定时器**
    //
    // 这就是 turning 卡 32 秒的根因：旧实现每句重试都 `_settleTimer?.cancel()`
    // 再 `Timer(settleTimeout, …)`，把 700ms 一直往后推，
    // 32 秒里从没连续空过 700ms → **一次都没响过**。
    // 现在：仍在"让位"（照旧返回 false，防连翻靠闸门本身），但**不再续期**，
    // 于是那第一个定时器必然响；即便它被别的原因弄丢，也还有硬上限兜底。
    if (_turning && !force) {
      _turnTargetPage = target;
      CrashLog.mark('AF[turnTo进行中] 第 $target 页（disp=$_displayedPage，不续期）');
      return false;
    }

    final distance = (target - _displayedPage).abs();

    if (distance > animateLimit) {
      // 大跨度：瞬时落位。**先记账再跳**（改动 4' 保留这个预写）——
      // 高亮按 `_displayedPage` 画，不预写就会"页面跳过去了、高亮还在旧页"。
      // 预写的代价由 `_jumpPending` 记录，`onPageSettled` / `onRevealFinished`
      // / 硬上限三处共同保证它不会永久为真。
      _displayedPage = target;
      _jumpPending = true;
      // ⚠️ jump 分支**不算「正在翻页」**（`_turning` 保持 false）——这是既有契约：
      //    「瞬时落位」是同步的一跳，没有动画在飞；把它标成 turning 会让
      //    `isTurning` 语义变味，也会让硬上限对着一个已经跳过去的页面空转。
      //    **预写的 `_displayedPage` 本身就足以防止"同一目标页重复发 jump"**
      //    （下一次 `target == _displayedPage`，由 `_jumpPending` 分支判断要不要重发）。
      _turnTargetPage = target;
      // ⚠️ **必须记开始时刻**：jump 是"预写了等确认"的状态，
      // 而硬上限正是用它来判"等了多久"。早先这里写 `_turnStartedAt = null`
      // 导致硬上限**永远不触发**（`started == null` 直接跳过），
      // 也就是"最需要兜底的情形反而不兜"（实测：jumps 停在 1）。
      _turnStartedAt = DateTime.now();
      _settleTimer?.cancel();
      _settleTimer = null; // jump 分支**不设定时器**，靠 onRevealFinished 解锁
      final action = jumpTo;
      if (action == null) {
        // 没有落位通道（控件还没挂上）：也要把"预写未确认"这个状态收干净
        _jumpPending = false;
        _turnTargetPage = null;
        return true;
      }
      CrashLog.mark('AF[turnTo开始] 第 $target 页 距离=$distance（瞬时落位）');
      // 落位同步触发落地回调 → setState，所以必须帧后做
      scheduleAfterFrame(() => action(target));
      return true;
    }

    // 相邻页：保留动画（跟读时看着自然）
    _turning = true;
    _turnTargetPage = target;
    _turnStartedAt ??= DateTime.now();
    _settleTimer?.cancel();
    if (animateTo == null) {
      // 没有落位通道（控件还没挂上）：也要把闸门关上，
      // 否则「翻页请求」会静默丢掉，而调用方以为已经在翻了 ——
      // 表现是朗读跑过好几页了画面还停在原地。
      _settleTimer = Timer(settleTimeout, () {
        _turning = false;
        _turnStartedAt = null;
      });
      return true;
    }
    _settleTimer = Timer(settleTimeout, () {
      // 落地回调没来也得放开闸门，否则永远卡住
      _turning = false;
      _turnStartedAt = null;
    });
    CrashLog.mark('AF[turnTo开始] 第 $target 页 距离=$distance（动画）');
    scheduleAfterFrame(() => animateTo!(target, animationDuration));
    return true;
  }

  void dispose() {
    _settleTimer?.cancel();
    _settleTimer = null;
    jumpTo = null;
    animateTo = null;
  }
}
