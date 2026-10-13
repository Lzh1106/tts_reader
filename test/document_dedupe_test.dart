import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/models/document.dart';
import 'package:tts_reader/services/storage_service.dart';

/// **文档库去重**（v1.21.43 重写版 · 块1）
///
/// ## 治什么（真机症状：一本书记两条）
///
/// 导入时 `id = DateTime.now().microsecondsSinceEpoch` —— **每次都不同**。
/// 而 `upsertDocument` 原来**只按 `id` 判重** → 同一个文件导入两次必然新增两条：
/// 一条坏的（半截文件）、一条好的，用户看到资料库里躺着两本同名书。
///
/// 真机截图证据（用户给的）：`下载/桃花源阅读器/` 里躺着同一个书名的两个残片
/// （2.76 MB 与 5.84 MB，来自两次都没下完的下载），文件名差一个 ` (1)`。
///
/// ## 三层判重（逐层放宽）
///
/// 1. **按 `id`** —— 原有行为（同一份记录更新）；
/// 2. **按 `path`** —— 同一个文件被导入两次；
/// 3. **按「书名去掉结尾 ` (n)`」+ 扩展名相同** —— 同名副本
///    （` (n)` 是本应用"重名让开"自己加的，不是服务端原名的一部分）。
///
/// 命中时**保留原记录的 id** —— `id` 被阅读页位置记录、封面文件名引用着，
/// 换 id 会让那些引用失联。
///
/// ⚠️ 本文件是 v1.21.42 丢失版本的**重写**，不是"恢复"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    storage = StorageService.instance;
    storage.resetForTest();
    await storage.init();
  });

  Document doc({
    required String id,
    required String title,
    required String path,
    DocumentType type = DocumentType.pdf,
    DateTime? importedAt,
  }) =>
      Document(
        id: id,
        title: title,
        path: path,
        type: type,
        importedAt: importedAt ?? DateTime(2026, 1, 1),
      );

  group('第 2 层：按 path 去重', () {
    test('同 path 用不同 id 再 upsert → 覆盖而不是新增，且保留原 id', () async {
      const samePath = '/tmp/同一本书.pdf';
      await storage.upsertDocument(
          doc(id: 'id-A', title: '同一本书', path: samePath));
      final first = await storage.loadDocuments();
      expect(first.where((d) => d.path == samePath).length, 1);

      // 第二次用**不同 id**（真机就是这种情况：id 是时间戳，必然不同）
      await storage.upsertDocument(
          doc(id: 'id-B', title: '同一本书', path: samePath));
      final second = await storage.loadDocuments();
      final same = second.where((d) => d.path == samePath).toList();

      // ignore: avoid_print
      print('DEVICE_VERIFY[dedupe-path] 同路径条数=${same.length} '
          '保留id=${same.isEmpty ? "-" : same.first.id}');
      expect(same.length, 1, reason: '同一个文件路径只能有一条记录');
      expect(same.first.id, 'id-A', reason: '必须保留原 id（被位置/封面引用着）');
    });

    test('path 两端空白不同也算同一个文件', () async {
      await storage.upsertDocument(
          doc(id: 'id-1', title: '书', path: '/tmp/a.pdf'));
      await storage.upsertDocument(
          doc(id: 'id-2', title: '书', path: '  /tmp/a.pdf  '));
      final docs = await storage.loadDocuments();
      expect(docs.where((d) => d.path.trim() == '/tmp/a.pdf').length, 1,
          reason: 'trim 后相同即同一文件');
    });
  });

  group('第 3 层：按「书名去掉结尾 (n)」去重', () {
    test('同名副本（收纳时加了 (1)）也要合并成一条', () async {
      await storage.upsertDocument(doc(
        id: 'id-X',
        title: '毛泽东评点二十四史领导干部读本（二册全） (肖威主编)',
        path: '/Download/桃花源阅读器/毛泽东评点二十四史（二册全）.pdf',
      ));
      await storage.upsertDocument(doc(
        id: 'id-Y',
        title: '毛泽东评点二十四史领导干部读本（二册全） (肖威主编) (1)',
        path: '/Download/桃花源阅读器/毛泽东评点二十四史（二册全） (1).pdf',
      ));

      final docs = await storage.loadDocuments();
      final matched =
          docs.where((d) => d.title.contains('毛泽东评点二十四史')).toList();
      // ignore: avoid_print
      print('DEVICE_VERIFY[dedupe-title] 同名副本条数=${matched.length} '
          '保留id=${matched.isEmpty ? "-" : matched.first.id}');
      expect(matched.length, 1,
          reason: '书名去掉结尾 (n) 后相同 + 扩展名相同 → 必须合并');
      expect(matched.first.id, 'id-X', reason: '保留最早那条的 id');
    });

    test('多层 (n) 连续去掉（(1) (2) 都算副本标记）', () async {
      await storage.upsertDocument(
          doc(id: 'a', title: '某书', path: '/tmp/a.pdf'));
      await storage.upsertDocument(
          doc(id: 'b', title: '某书 (1)', path: '/tmp/a (1).pdf'));
      await storage.upsertDocument(
          doc(id: 'c', title: '某书 (2)', path: '/tmp/a (2).pdf'));
      final docs = await storage.loadDocuments();
      expect(docs.where((d) => d.title.startsWith('某书')).length, 1,
          reason: '(1)(2) 都是同名副本，应合成一条');
    });

    test('书名中间带括号的不会被误判（(肖威主编) 不是副本标记）', () async {
      await storage.upsertDocument(
          doc(id: 'p', title: '某书 (作者甲)', path: '/tmp/a.pdf'));
      await storage.upsertDocument(
          doc(id: 'q', title: '某书 (作者乙)', path: '/tmp/b.pdf'));
      final docs = await storage.loadDocuments();
      expect(docs.where((d) => d.title.startsWith('某书')).length, 2,
          reason: '作者不同的两本书不能被合并');
    });

    test('同名但扩展名不同不合并（.pdf 与 .epub 是两种书）', () async {
      await storage.upsertDocument(
          doc(id: 'r', title: '同名书', path: '/tmp/same.pdf'));
      await storage.upsertDocument(doc(
          id: 's',
          title: '同名书',
          path: '/tmp/same.epub',
          type: DocumentType.epub));
      final docs = await storage.loadDocuments();
      expect(docs.where((d) => d.title == '同名书').length, 2,
          reason: '扩展名不同视为不同文件');
    });

    test('书名完全不同的两本书不会被合并（不能过度去重）', () async {
      await storage.upsertDocument(
          doc(id: 'x', title: '第一本书', path: '/tmp/1.pdf'));
      await storage.upsertDocument(
          doc(id: 'y', title: '第二本书', path: '/tmp/2.pdf'));
      final docs = await storage.loadDocuments();
      expect(docs.length, 2, reason: '不同书必须都留下');
    });
  });

  group('原有行为不能被弄坏', () {
    test('同 id upsert → 覆盖（进度 / 封面更新走这条）', () async {
      await storage.upsertDocument(
          doc(id: 'same', title: '书', path: '/tmp/a.pdf'));
      await storage.upsertDocument(doc(
          id: 'same',
          title: '书',
          path: '/tmp/a.pdf',
          importedAt: DateTime(2026, 2, 2)));
      final docs = await storage.loadDocuments();
      expect(docs.length, 1, reason: '同 id 必须覆盖，不能新增');
    });

    test('去重命中时会保留原有封面（不回退成 null）', () async {
      await storage.upsertDocument(doc(
              id: 'with-cover', title: '带封面的书', path: '/tmp/c.pdf')
          .copyWith(coverPath: '/covers/with-cover.jpg'));
      // 第二次 upsert 没带封面（例如下载导入那条路）
      await storage.upsertDocument(
          doc(id: 'other-id', title: '带封面的书', path: '/tmp/c.pdf'));
      final docs = await storage.loadDocuments();
      final hit = docs.firstWhere((d) => d.path == '/tmp/c.pdf');
      // ignore: avoid_print
      print('DEVICE_VERIFY[dedupe-cover] 保留封面=${hit.coverPath}');
      expect(hit.coverPath, '/covers/with-cover.jpg',
          reason: '去重不能让已有封面丢掉');
    });
  });
}
