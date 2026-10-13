import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_reader/pages/browser_page.dart';

/// **下载列表里「叉 / 垃圾桶」的状态分派**（v1.21.39）
///
/// 用户要求：下载列表每一项后面加叉（取消/移除）。
/// 这两件事**语义完全不同**，搞错的后果不对称：
/// - 进行中的任务 → `cancel(taskId:)`（真的停止下载）
/// - 已结束的任务 → `remove(shouldDeleteContent: **false**)`（只移出列表）
///
/// ⚠️ 尤其 `shouldDeleteContent` 必须是 false：文件可能已经被自动导入文档库，
/// 删了内容书就打不开 —— 那比"列表里多一条记录"严重得多。
/// 这条用例把"哪个状态走哪条路"钉死，避免以后有人顺手改成 true 或反过来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('进行中 → 取消（叉）', () {
    test('enqueued / running / paused 都算进行中', () {
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.enqueued), isTrue);
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.running), isTrue);
      // paused 只是被系统暂停，用户想的是"别下了"，不是"从列表删掉"
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.paused), isTrue,
          reason: '暂停中的任务应当可以取消，而不是只能移出列表');
    });

    test('进行中显示叉（Icons.close），不是垃圾桶', () {
      for (final status in <DownloadTaskStatus>[
        DownloadTaskStatus.enqueued,
        DownloadTaskStatus.running,
        DownloadTaskStatus.paused,
      ]) {
        expect(BrowserPage.trailingIconFor(status), Icons.close,
            reason: '$status 应当显示叉（取消下载）');
      }
    });
  });

  group('已结束 → 移出列表（垃圾桶）', () {
    test('complete / failed / canceled 都算已结束', () {
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.complete), isFalse);
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.failed), isFalse);
      expect(BrowserPage.isActiveTask(DownloadTaskStatus.canceled), isFalse);
    });

    test('已结束显示垃圾桶（Icons.delete_outline），不是叉', () {
      for (final status in <DownloadTaskStatus>[
        DownloadTaskStatus.complete,
        DownloadTaskStatus.failed,
        DownloadTaskStatus.canceled,
      ]) {
        expect(BrowserPage.trailingIconFor(status), Icons.delete_outline,
            reason: '$status 应当显示垃圾桶（只移除记录）');
      }
    });

    test('未知状态按"已结束"处理（不移出内容，最保守）', () {
      // 插件状态是原生枚举，未来新增值时不能默认成"进行中"——
      // 那会给用户一个"取消"按钮，点了却没反应（任务根本不在跑）
      expect(BrowserPage.isActiveTask(null), isFalse);
      expect(BrowserPage.trailingIconFor(null), Icons.delete_outline);
    });
  });

  group('⚠️ 插件报失败但文件已下好 → 不能认输（v1.21.41 真机反馈）', () {
    // 用户实测：文件已经完整下好了，而插件报"下载失败"、进度条只走了一点
    // → 原来的实现把 failed/canceled 当终态立即放弃 → 自动导入没生效。
    // 结论：插件的状态与磁盘事实可能不一致，这时该信磁盘。
    test('failed / canceled + 磁盘有非空文件 → 按"已下好"处理', () {
      expect(BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.failed, 1321),
          isTrue);
      expect(
          BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.canceled, 99),
          isTrue);
      // ignore: avoid_print
      print('DEVICE_VERIFY[download-probe] failed+1321B → 接受');
    });

    test('磁盘上没有文件 / 空文件 → 仍然认输（别把半截文件当成品）', () {
      expect(BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.failed, null),
          isFalse);
      expect(BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.failed, 0),
          isFalse,
          reason: '边下边写时文件会先出现 —— 0 字节不是"下好了"');
      expect(
          BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.canceled, null),
          isFalse);
    });

    test('非失败状态不走这条（complete 有自己的分支）', () {
      expect(
          BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.complete, 100),
          isFalse);
      expect(
          BrowserPage.shouldAcceptFailedDownload(DownloadTaskStatus.running, 100),
          isFalse);
      expect(BrowserPage.shouldAcceptFailedDownload(null, 100), isFalse);
    });
  });

  group('两个按钮语义不能互换（回归保护）', () {
    test('叉 = 取消，垃圾桶 = 移除，集合完整且互斥', () {
      const all = DownloadTaskStatus.values;
      final active = all.where(BrowserPage.isActiveTask).toSet();
      final done = all.where((s) => !BrowserPage.isActiveTask(s)).toSet();
      expect(active.intersection(done), isEmpty,
          reason: '一个状态不能既算进行中又算已结束');
      expect(active.union(done), all.toSet(),
          reason: '每个状态都要有明确的归属，不能漏');
      // ignore: avoid_print
      print('DEVICE_VERIFY[download-trailing] 取消=${active.map((e) => e.name)} '
          '移除=${done.map((e) => e.name)}');
    });
  });
}
