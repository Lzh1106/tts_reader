import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「切书后却读回旧书」——**引擎重投代次校验**的回归（v1.21.54）
///
/// ## 缺陷机理（实测复现，见下）
///
/// `SystemTtsEngine.speak()` 在提交被插件丢弃（返回 0）时会重投，
/// 间隔 `150ms`、最多 `8` 次 ≈ **1.2 秒**。
///
/// 修复前 [submit] **不检查这次朗读是否已作废**，于是：
/// ```
/// t=0    书A 最后一句进入重投
/// t=50   用户切到书B → stop()
/// t=150  重投到点 → 把【A 的文本】再交给系统 → 念出来的还是书A
/// ```
/// 这正是用户报的「书A暂停 → 打开书B → 恢复却读书A」：
/// 与在哪一页、点哪个按钮、哪本书**都无关**。
///
/// ## 为什么用源码断言而不是运行断言
///
/// `SystemTtsEngine` 内部直接 `new FlutterTts()`，插件无法注入，
/// 纯 Dart 测试里跑不到真实引擎。所以这里钉**代码契约**：
/// 重投函数里必须存在代次校验、且 `stop()`/`pause()` 必须递增代次。
/// 任何一处被删掉，这条用例立刻变红。
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/tts/system_tts_engine.dart').readAsStringSync();
  });

  test('★重投前必须校验代次（否则切书后仍会念旧书）', () {
    expect(source.contains('int _generation = 0;'), isTrue,
        reason: '必须有代次字段：用来判定"这次朗读是否已作废"');

    // ⚠️ 判据必须检查「**生效的**代码行」，不能只 `contains` 字符串 ——
    // 否则把这一行注释掉（前面加 `//`）用例照样绿，等于没测到
    // （v1.21.54 负向自检当场抓到过这个假测试）。
    final activeLines = source
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('//'))
        .toList();
    final guard = activeLines.where(
      (line) => line.contains('myGeneration != _generation'),
    );
    expect(guard, isNotEmpty,
        reason: '★重投提交前必须校验代次（且这一行必须是**生效代码**，不能被注释掉）—— '
            '少了它，stop() 之后排着的重投仍会把旧书文本交给系统，'
            '用户就会听到"读回书A"');
  });

  test('★stop() 必须作废在飞的重投', () {
    final stopBody = _methodBody(source, 'Future<void> stop() async');
    expect(stopBody.contains('_generation++'), isTrue,
        reason: '★stop() 必须递增代次（换书/停止 = 旧的朗读作废），'
            '否则重投会继续念旧书');
    expect(stopBody.contains('_tts.stop()'), isTrue,
        reason: '同时要真的停掉系统侧队列');
  });

  test('★pause() 也要作废在飞的重投', () {
    final pauseBody = _methodBody(source, 'Future<void> pause() async');
    expect(pauseBody.contains('_generation++'), isTrue,
        reason: '暂停之后同样不该再有旧文本被提交');
  });

  test('新一次 speak() 必须换新代次（否则上一次的重投会跟着这次复活）', () {
    expect(source.contains('final int myGeneration = ++_generation;'), isTrue,
        reason: '每次 speak 都要领一个新的代次，旧的重投随之失效');
  });

  test('重投次数与间隔仍在合理范围（8 次 / 150ms，别被顺手改大）', () {
    expect(source.contains('_submitAttempts = 8'), isTrue);
    expect(source.contains('_submitRetryDelay = Duration(milliseconds: 150)'),
        isTrue);
  });
}

/// 取某个方法从签名到**下一个同级 `@override` 或类尾**之间的源码
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThan(-1), reason: '找不到方法：$signature');
  final next = source.indexOf('@override', start + signature.length);
  return source.substring(start, next == -1 ? source.length : next);
}
