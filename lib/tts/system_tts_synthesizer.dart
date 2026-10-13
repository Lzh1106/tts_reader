import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../services/crash_log.dart';

/// 用系统 TTS 把文本合成成音频文件（Android / iOS 支持）
///
/// 两点必须守住（和朗读链路同一个坑）：
/// 1. **插件不回复时不能不返回**：flutter_tts 的合成在出错分支里不会给
///    `synthResult` 回值，裸 await 会永久挂住导出流程，所以这里统一走 [bounded]。
/// 2. **不能并发调用**：插件内部用 `synth` 标志挡住重复合成，第二次调用直接
///    返回 0（等于失败），所以每次都必须等到上一次真正结束。
class SystemTtsSynthesizer {
  SystemTtsSynthesizer({this.rate = 1.0, this.pitch = 1.0, this.voiceId = ''});

  /// 与朗读设置保持一致的语速 / 音调 / 音色
  final double rate;
  final double pitch;
  final String voiceId;

  /// 单片合成的等待上限（正常一段话几秒，超过说明引擎已经不响应了）
  static const Duration synthTimeout = Duration(seconds: 60);

  FlutterTts? _tts;
  bool _ready = false;

  /// 是否已被用户取消
  bool _cancelled = false;

  /// 是否已被用户取消（导出页据此在下一片开始前收尾）
  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  Future<FlutterTts> _ensure() async {
    final existing = _tts;
    if (existing != null && _ready) return existing;
    final tts = existing ?? FlutterTts();
    _tts = tts;
    await bounded(() async {
      await tts.awaitSynthCompletion(true);
      await tts.setSpeechRate(rate);
      await tts.setPitch(pitch);
      if (voiceId.isNotEmpty) {
        try {
          await tts.setVoice(<String, String>{'name': voiceId});
        } catch (_) {
          // 部分引擎不接受按名字指定音色，失败不影响合成
        }
      }
    }, const Duration(seconds: 8));
    _ready = true;
    return tts;
  }

  /// 合成一片文本到 [fileName]
  ///
  /// [fileName] 交给平台侧当文件名：Android 11+ 会存进媒体库的「音乐」目录，
  /// 更早的版本写进外部存储的 Music 目录（需要写权限）。
  Future<bool> synthesize(String text, String fileName) async {
    if (_cancelled || text.trim().isEmpty) return false;
    final tts = await _ensure();
    var ok = false;
    await bounded(() async {
      await tts.synthesizeToFile(text, fileName);
      ok = true;
    }, synthTimeout);
    if (!ok) CrashLog.mark('导出音频：合成「$fileName」失败或超时');
    return ok;
  }

  Future<void> dispose() async {
    final tts = _tts;
    _tts = null;
    _ready = false;
    if (tts == null) return;
    try {
      await bounded(() async => tts.stop(), const Duration(seconds: 3));
    } catch (_) {
      // 停止失败无所谓，实例就要丢掉了
    }
  }

  /// 等「完成 / 超时」谁先到；超时后撤掉定时器
  ///
  /// 不用 `Future.timeout()`：它在操作永不完成时不会取消内部定时器，
  /// 会留下悬挂定时器（测试里报 "A Timer is still pending"）。
  static Future<bool> bounded(Future<void> Function() operation, Duration timeout) {
    final completer = Completer<bool>();
    Timer? timer;
    void finish(bool value) {
      if (completer.isCompleted) return;
      timer?.cancel();
      timer = null;
      completer.complete(value);
    }

    timer = Timer(timeout, () => finish(false));
    operation().then((_) => finish(true), onError: (Object _, StackTrace __) => finish(false));
    return completer.future;
  }
}
