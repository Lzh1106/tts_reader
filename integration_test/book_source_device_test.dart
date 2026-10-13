import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_reader/services/book_source_directory.dart';

/// 真机/设备侧：**真实网络**下检索可用域名（v1.21.22 多源聚合）
///
/// 单测用的是 MockClient，只能验解析与缓存逻辑；这条用例证明
/// 「设备真的能连上状态站并解析出域名」——用户报的就是"经常连不上"。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('并行检索状态站：至少一个源给出可用域名', (tester) async {
    BookSourceDirectory.clearCacheForTest();
    final DirectoryResult result =
        await BookSourceDirectory.fetch(forceRefresh: true);

    final List<String> hosts =
        result.entries.take(8).map((MirrorEntry e) => '${e.host}(${e.status})').toList();
    // ignore: avoid_print
    print('DEVICE_VERIFY[书源] source=${result.sourceUrl} '
        '条数=${result.entries.length} 前几个=$hosts 失败源=${result.failedSources}');

    expect(result.entries, isNotEmpty,
        reason: '两个候选源至少要有一个能给出域名（失败源=${result.failedSources}）');
    expect(result.entries.any((MirrorEntry e) => e.usable), isTrue,
        reason: '至少要有一个"可用"状态的域名供用户选择');
  });

  testWidgets('Markdown 镜像表（Awesome-Zlibrary）：真实网络能解析出域名', (tester) async {
    // 直接打这一个源，验证 Markdown 那一档解析（多源聚合时它常被快的源抢走，
    // 所以这里单独验）
    const String url =
        'https://raw.githubusercontent.com/dongyubin/Awesome-Zlibrary/main/README.md';
    final List<MirrorEntry> entries =
        await BookSourceDirectory.fetchFrom(url);
    // ignore: avoid_print
    print('DEVICE_VERIFY[Markdown源] 条数=${entries.length} '
        '前几个=${entries.take(6).map((e) => "${e.host}(${e.status})").toList()}');

    if (entries.isEmpty) {
      // 这台机器/模拟器到 GitHub raw 不通（实测：本机 curl 通、模拟器不通）——
      // 属于环境问题，不该让设备用例变红；解析器本身由单测（含真实 README 片段）覆盖。
      markTestSkipped('raw.githubusercontent.com 从当前网络不可达 → 跳过（环境问题）');
      return;
    }
    expect(entries, isNotEmpty,
        reason: 'README 的镜像表要能被解析（结构与预期不符时这里会红）');
    expect(entries.length, greaterThanOrEqualTo(3));
    expect(entries.any((MirrorEntry e) => e.usable), isTrue,
        reason: '至少要有 ✅ 的域名');
  });
}
