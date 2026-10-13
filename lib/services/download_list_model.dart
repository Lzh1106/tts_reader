import 'package:flutter_downloader/flutter_downloader.dart';

/// 下载列表的分组（Chrome 式：**正在下载 / 已完成 / 失败**）
enum DownloadSection {
  /// 排队中 / 下载中 / 已暂停 —— 都还能被"取消"，也还能继续
  active,

  /// 下完了（文件已经在磁盘上）
  complete,

  /// 失败 / 被取消 / 状态未知 —— 都给"重试 + 移除"
  failed,
}

/// 一组下载任务（[section] + 组内任务；组内已排序，空组不会出现在列表里）
class DownloadGroup {
  const DownloadGroup(this.section, this.tasks);

  final DownloadSection section;
  final List<DownloadTask> tasks;

  int get length => tasks.length;
}

/// **下载列表的纯逻辑**：分组 / 来源站点名 / 每项能做什么
///
/// ## 为什么单独一份，而且全是静态纯函数
///
/// 1. **真机验证是这个工程最贵的一步**（要插线、要装包、要人盯着屏幕点）。
///    而"哪个状态算正在下载""这一项该出现哪几个按钮""来源显示成什么名字"
///    这些判据**不需要手机就能钉住** —— 用例跑一遍几毫秒。
/// 2. 这类判据以前写在 `_showDownloads` 的 builder 里（`switch` + 三元），
///    改一处就得重新点开手机看一遍；抽出来之后，"看界面才知道对不对"
///    的部分只剩排版，语义部分全部可断言。
///
/// ⚠️ 这里**不 import Flutter 的 UI**（`IconData`、`Widget` 都不碰）：
/// 图标属于界面，留在页面里；这里只管"哪些动作可用"。
class DownloadListModel {
  DownloadListModel._();

  /// 这几态算**正在下载**（`paused` 也算 —— 它只是被系统暂停，还能继续）
  ///
  /// ⚠️ 与 `BrowserPage.isActiveTask` 是**同一份判据**：那边已改为转调这里，
  /// 免得两处各写一套 `switch`（这类漂移在这个工程里出过不止一次）。
  static bool isActive(DownloadTaskStatus? status) =>
      status == DownloadTaskStatus.enqueued ||
      status == DownloadTaskStatus.running ||
      status == DownloadTaskStatus.paused;

  /// 这条任务归哪一组
  static DownloadSection sectionOf(DownloadTaskStatus? status) {
    if (isActive(status)) return DownloadSection.active;
    if (status == DownloadTaskStatus.complete) {
      return DownloadSection.complete;
    }
    // failed / canceled / undefined：**一律归「失败」**，给"重试 + 移除"。
    // 不能归到「已完成」—— 那会让用户点开一个根本打不开的文件，
    // 而"点开是坏的"比"显示成失败"严重得多（半截文件事故的教训）。
    return DownloadSection.failed;
  }

  /// 分组标题（中文，界面直接用）
  static String sectionTitle(DownloadSection section) => switch (section) {
        DownloadSection.active => '正在下载',
        DownloadSection.complete => '已完成',
        DownloadSection.failed => '失败',
      };

  /// 分组从上到下的顺序（Chrome 也是"进行中的在最上面"）
  static const List<DownloadSection> sectionOrder = <DownloadSection>[
    DownloadSection.active,
    DownloadSection.complete,
    DownloadSection.failed,
  ];

  /// 按状态分组：**空组不返回**；组内**新任务排前面**
  ///
  /// 排序键：`timeCreated` 倒序；同一毫秒（插件批量写入时真会发生）再用
  /// `taskId` 兜底 —— 否则同一个列表两次刷新的顺序可能不一样，
  /// 界面上表现为"列表自己跳"，用例也没法断言。
  static List<DownloadGroup> groupsOf(List<DownloadTask> tasks) {
    final Map<DownloadSection, List<DownloadTask>> bucket =
        <DownloadSection, List<DownloadTask>>{
      for (final s in sectionOrder) s: <DownloadTask>[],
    };
    for (final task in tasks) {
      bucket[sectionOf(task.status)]!.add(task);
    }
    final List<DownloadGroup> groups = <DownloadGroup>[];
    for (final section in sectionOrder) {
      final List<DownloadTask> list = bucket[section]!;
      if (list.isEmpty) continue; // 空组不出现在界面里
      final List<DownloadTask> sorted = List<DownloadTask>.of(list)
        ..sort((a, b) {
          final int byTime = b.timeCreated.compareTo(a.timeCreated);
          return byTime != 0 ? byTime : a.taskId.compareTo(b.taskId);
        });
      groups.add(DownloadGroup(section, List<DownloadTask>.unmodifiable(sorted)));
    }
    return groups;
  }

  // ---------------- 每项能做什么（界面据此决定显示哪些按钮） ----------------

  /// 能不能「暂停」（只有真正在跑的才需要暂停）
  static bool canPause(DownloadTaskStatus? status) =>
      status == DownloadTaskStatus.enqueued ||
      status == DownloadTaskStatus.running;

  /// 能不能「继续」（只有被暂停过的能继续）
  static bool canResume(DownloadTaskStatus? status) =>
      status == DownloadTaskStatus.paused;

  /// 能不能「取消」（进行中的都能取消，含暂停中的）
  static bool canCancel(DownloadTaskStatus? status) => isActive(status);

  /// 能不能「重试」（失败 / 被取消才有意义）
  static bool canRetry(DownloadTaskStatus? status) =>
      status == DownloadTaskStatus.failed ||
      status == DownloadTaskStatus.canceled;

  /// 能不能「打开」（只有真的下完了才谈打开）
  static bool canOpen(DownloadTaskStatus? status) =>
      status == DownloadTaskStatus.complete;

  /// 能不能「移出列表」（已结束的才能移；进行中的那个按钮是"取消"）
  ///
  /// ⚠️ 移出列表**永远**只删记录、不删文件（`shouldDeleteContent: false`）：
  /// 文件可能已经被自动导入文档库，删了书就打不开。
  static bool canRemove(DownloadTaskStatus? status) => !isActive(status);

  /// 进度条取值（0~1）：插件给的是 0~100 的整数，夹一下防脏数据
  static double progressFraction(int progress) => progress.clamp(0, 100) / 100;

  /// 状态文案（中文，界面直接用）
  static String statusLabel(DownloadTaskStatus? status) => switch (status) {
        DownloadTaskStatus.complete => '已完成',
        DownloadTaskStatus.running => '下载中',
        DownloadTaskStatus.enqueued => '排队中',
        DownloadTaskStatus.paused => '已暂停',
        DownloadTaskStatus.failed => '失败',
        DownloadTaskStatus.canceled => '已取消',
        _ => '未知',
      };

  // ---------------- 来源站点 ----------------

  /// **来源域名映射表**：能认出来的站点给个人话名字，认不出来的回落主机名
  ///
  /// 判据是"主机名里**含**这个键"（不是相等）：镜像域名太多
  /// （`z-lib.sk` / `1lib.sk` / `z-lib.io` / `zh.z-lib.gs` …），
  /// 逐个列全既列不完、也会随时间失效，所以只认**特征串**。
  ///
  /// ⚠️ 顺序有意义：先匹配到的先赢，所以**特征越具体的排越前**。
  static const Map<String, String> knownSites = <String, String>{
    'z-lib': 'Z-Library',
    'zlibrary': 'Z-Library',
    '1lib': 'Z-Library',
    'annas-archive': 'Anna’s Archive',
    'libgen': 'Library Genesis',
    'standardebooks': 'Standard Ebooks',
    'gutenberg': 'Project Gutenberg',
    'archive.org': 'Internet Archive',
    'github': 'GitHub',
    'baidu': '百度网盘',
    'aliyundrive': '阿里云盘',
    'alipan': '阿里云盘',
    'quark': '夸克网盘',
    '123pan': '123 云盘',
    'lanzou': '蓝奏云',
    'weiyun': '腾讯微云',
    'ctfile': '城通网盘',
  };

  /// 取出主机名（小写、去掉 `www.`；解析不出来返回空串）
  static String hostOf(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    final String host = (uri?.host ?? '').toLowerCase();
    if (host.isEmpty) return '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// 来源站点显示名：先查 [knownSites]（特征串匹配），再回落主机名本身
  ///
  /// 认不出来时**显示主机名**而不是"未知来源"：用户至少能看出是从哪个站下的，
  /// 而这正是他要的信息（"这本是从 z-lib 下的还是从别处下的"）。
  static String sourceLabel(String url) {
    final String host = hostOf(url);
    if (host.isEmpty) return '未知来源';
    for (final entry in knownSites.entries) {
      if (host.contains(entry.key)) return entry.value;
    }
    return host;
  }
}
