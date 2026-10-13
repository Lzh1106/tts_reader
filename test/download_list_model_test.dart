import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/services/download_list_model.dart';

/// **下载列表的纯逻辑**（本轮 · 需求二：Chrome 式下载列表）
///
/// ## 为什么这些判据值得单独钉住
///
/// 用户要的列表是"进度条 + 分组（正在下载 / 已完成）+ 暂停 / 继续 / 取消 /
/// 打开 / 重试 + 来源域名"。这里面**真正容易错**的不是排版，而是三类判断：
///
/// 1. **归组**：`paused` 算"正在下载"（它还能继续/取消），`canceled` 算"失败"
///    （不能混进"已完成"让用户点开一个打不开的文件）；
/// 2. **每项该出现哪些按钮**：给一个已经完成的任务显示"暂停"就是死按钮；
/// 3. **来源站点**：镜像域名列不完，只能按特征串认（`z-lib.sk` / `1lib.sk` …）。
///
/// 这三类判据**不需要手机就能验**，而真机验证是这个工程最贵的一步 ——
/// 所以它们全部搬进 [DownloadListModel]，在这里钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask task({
    String id = 't1',
    DownloadTaskStatus status = DownloadTaskStatus.running,
    int progress = 0,
    String url = 'https://example.com/a.pdf',
    String? name = 'a.pdf',
    int created = 1000,
  }) =>
      DownloadTask(
        taskId: id,
        status: status,
        progress: progress,
        url: url,
        filename: name,
        savedDir: '/storage/emulated/0/Download',
        timeCreated: created,
        allowCellular: true,
      );

  group('归组：正在下载 / 已完成 / 失败', () {
    test('排队中 / 下载中 / 已暂停 → 正在下载（暂停的还能继续，不算结束）', () {
      for (final s in <DownloadTaskStatus>[
        DownloadTaskStatus.enqueued,
        DownloadTaskStatus.running,
        DownloadTaskStatus.paused,
      ]) {
        expect(DownloadListModel.sectionOf(s), DownloadSection.active,
            reason: '$s 应当是"正在下载"');
      }
    });

    test('已完成 → 已完成组', () {
      expect(DownloadListModel.sectionOf(DownloadTaskStatus.complete),
          DownloadSection.complete);
    });

    test('失败 / 已取消 / 未知 → 失败组（**绝不能混进"已完成"**）', () {
      for (final s in <DownloadTaskStatus?>[
        DownloadTaskStatus.failed,
        DownloadTaskStatus.canceled,
        DownloadTaskStatus.undefined,
        null,
      ]) {
        expect(DownloadListModel.sectionOf(s), DownloadSection.failed,
            reason: '$s 归到"已完成"会让用户点开一个打不开的文件');
      }
    });

    test('空组不出现在列表里（没失败过就不该有「失败（0）」这一行）', () {
      expect(DownloadListModel.groupsOf(<DownloadTask>[]), isEmpty);
      final groups = DownloadListModel.groupsOf(<DownloadTask>[
        task(id: 'a', status: DownloadTaskStatus.complete),
      ]);
      expect(groups.length, 1);
      expect(groups.single.section, DownloadSection.complete);
      expect(groups.single.length, 1);
    });

    test('组顺序：正在下载 → 已完成 → 失败（进行中的在最上面）', () {
      final groups = DownloadListModel.groupsOf(<DownloadTask>[
        task(id: 'f', status: DownloadTaskStatus.failed),
        task(id: 'c', status: DownloadTaskStatus.complete),
        task(id: 'a', status: DownloadTaskStatus.running),
      ]);
      expect(groups.map((g) => g.section).toList(), <DownloadSection>[
        DownloadSection.active,
        DownloadSection.complete,
        DownloadSection.failed,
      ]);
    });

    test('组内新任务排前面；同一毫秒用 taskId 兜底（顺序必须稳定）', () {
      final groups = DownloadListModel.groupsOf(<DownloadTask>[
        task(id: 'old', status: DownloadTaskStatus.complete, created: 100),
        task(id: 'zzz', status: DownloadTaskStatus.complete, created: 200),
        task(id: 'aaa', status: DownloadTaskStatus.complete, created: 200),
      ]);
      expect(groups.single.tasks.map((t) => t.taskId).toList(),
          <String>['aaa', 'zzz', 'old'],
          reason: '同一毫秒按 taskId 升序 —— 否则两次刷新列表会自己跳');
    });
  });

  group('每项出现哪些按钮（按状态）', () {
    test('排队中 / 下载中：能暂停、能取消，不能继续 / 打开 / 重试', () {
      for (final s in <DownloadTaskStatus>[
        DownloadTaskStatus.enqueued,
        DownloadTaskStatus.running,
      ]) {
        expect(DownloadListModel.canPause(s), isTrue, reason: '$s 能暂停');
        expect(DownloadListModel.canCancel(s), isTrue, reason: '$s 能取消');
        expect(DownloadListModel.canResume(s), isFalse);
        expect(DownloadListModel.canOpen(s), isFalse);
        expect(DownloadListModel.canRetry(s), isFalse);
      }
    });

    test('已暂停：能继续、能取消；**不显示暂停**（否则是个死按钮）', () {
      expect(DownloadListModel.canResume(DownloadTaskStatus.paused), isTrue);
      expect(DownloadListModel.canCancel(DownloadTaskStatus.paused), isTrue);
      expect(DownloadListModel.canPause(DownloadTaskStatus.paused), isFalse);
      expect(DownloadListModel.canOpen(DownloadTaskStatus.paused), isFalse);
    });

    test('已完成：能打开、能移除；不能暂停 / 继续 / 重试', () {
      const s = DownloadTaskStatus.complete;
      expect(DownloadListModel.canOpen(s), isTrue);
      expect(DownloadListModel.canRemove(s), isTrue);
      expect(DownloadListModel.canPause(s), isFalse);
      expect(DownloadListModel.canResume(s), isFalse);
      expect(DownloadListModel.canRetry(s), isFalse);
    });

    test('失败 / 已取消：能重试、能移除；**不能打开**', () {
      for (final s in <DownloadTaskStatus>[
        DownloadTaskStatus.failed,
        DownloadTaskStatus.canceled,
      ]) {
        expect(DownloadListModel.canRetry(s), isTrue, reason: '$s 能重试');
        expect(DownloadListModel.canRemove(s), isTrue, reason: '$s 能移除');
        expect(DownloadListModel.canOpen(s), isFalse,
            reason: '$s 打不开 —— 文件根本没下完');
        expect(DownloadListModel.canCancel(s), isFalse);
      }
    });

    test('取消与移除互斥且覆盖全部状态（同一个按钮不能有两种语义）', () {
      for (final s in <DownloadTaskStatus?>[...DownloadTaskStatus.values, null]) {
        expect(DownloadListModel.canCancel(s) != DownloadListModel.canRemove(s),
            isTrue,
            reason: '$s 必须**恰好**落在"取消"或"移除"其中一个上');
      }
    });
  });

  group('进度', () {
    test('0~100 正常换算成 0~1', () {
      expect(DownloadListModel.progressFraction(0), 0.0);
      expect(DownloadListModel.progressFraction(45), 0.45);
      expect(DownloadListModel.progressFraction(100), 1.0);
    });

    test('脏数据（负数 / 超过 100）被夹住：进度条不能画出界', () {
      expect(DownloadListModel.progressFraction(-20), 0.0);
      expect(DownloadListModel.progressFraction(420), 1.0);
    });
  });

  group('来源域名映射表', () {
    test('Z-Library 的镜像都认得出（只认特征串，不逐个列域名）', () {
      for (final host in <String>[
        'z-lib.sk',
        'zh.z-lib.gs',
        '1lib.sk',
        'zlibrary.to',
      ]) {
        expect(DownloadListModel.sourceLabel('https://$host/ book.pdf'),
            'Z-Library',
            reason: '$host 是 Z-Library 的镜像');
      }
    });

    test('其它认得出的站点', () {
      expect(DownloadListModel.sourceLabel('https://libgen.is/a.pdf'),
          'Library Genesis');
      expect(DownloadListModel.sourceLabel('https://annas-archive.org/a.pdf'),
          'Anna’s Archive');
      expect(DownloadListModel.sourceLabel('https://www.gutenberg.org/a.txt'),
          'Project Gutenberg');
      expect(DownloadListModel.sourceLabel('https://pan.baidu.com/s/xyz'),
          '百度网盘');
    });

    test('认不出来的：回落主机名（去掉 www.），而不是"未知来源"', () {
      expect(DownloadListModel.sourceLabel('https://www.example.com/a.pdf'),
          'example.com');
      expect(DownloadListModel.hostOf('HTTP://Example.COM:8080/a.pdf'),
          'example.com',
          reason: '大小写与端口都要归一化');
    });

    test('地址不成形 → 未知来源（不抛异常）', () {
      expect(DownloadListModel.sourceLabel(''), '未知来源');
      expect(DownloadListModel.hostOf('不是网址'), '');
    });
  });

  group('状态文案', () {
    test('每个状态都有中文文案（界面直接用）', () {
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.complete), '已完成');
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.running), '下载中');
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.enqueued), '排队中');
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.paused), '已暂停');
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.failed), '失败');
      expect(DownloadListModel.statusLabel(DownloadTaskStatus.canceled), '已取消');
      expect(DownloadListModel.statusLabel(null), '未知');
    });

    test('三个分组标题与用户看到的一致', () {
      expect(DownloadListModel.sectionTitle(DownloadSection.active), '正在下载');
      expect(DownloadListModel.sectionTitle(DownloadSection.complete), '已完成');
      expect(DownloadListModel.sectionTitle(DownloadSection.failed), '失败');
    });
  });
}
