import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'tts_engine.dart';

/// 把内存里的音频字节包装成 just_audio 可播放的数据源
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this._bytes) : super(tag: 'cloud-tts');

  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream<List<int>>.value(_bytes.sublist(from, to)),
      contentType: 'audio/mpeg',
    );
  }
}

/// 云端 TTS 引擎：POST {baseUrl, apiKey}，OpenAI 兼容格式
/// body: {model: 'tts-1', input, voice, speed}，响应为音频二进制
class CloudTtsEngine implements TtsEngine {
  CloudTtsEngine({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
    AudioPlayer? player,
  }) : _baseUrl = baseUrl,
       _apiKey = apiKey,
       _client = client ?? http.Client(),
       _player = player ?? AudioPlayer();

  final http.Client _client;
  final AudioPlayer _player;

  String _baseUrl;
  String _apiKey;
  String _voice = 'alloy';
  double _rate = 1.0;

  Completer<void>? _pending;
  void Function()? _onComplete;
  bool _disposed = false;

  @override
  String get id => 'cloud';

  @override
  String get displayName => '云端 TTS';

  @override
  bool get isAvailable =>
      !_disposed && _baseUrl.trim().isNotEmpty && _apiKey.trim().isNotEmpty;

  /// 设置页保存后动态更新配置
  void updateConfig({required String baseUrl, required String apiKey}) {
    _baseUrl = baseUrl.trim();
    _apiKey = apiKey.trim();
  }

  /// 请求地址：给到 host 时自动补 /audio/speech
  Uri get _endpoint {
    final trimmed = _baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = trimmed.endsWith('/audio/speech') ? trimmed : '$trimmed/audio/speech';
    return Uri.parse(url);
  }

  @override
  Future<void> initialize() async {
    if (_disposed) throw StateError('云端 TTS 引擎已释放');
  }

  @override
  Future<List<TtsVoice>> getVoices() async => const <TtsVoice>[
    TtsVoice(id: 'alloy', name: 'Alloy 中性', locale: 'cloud'),
    TtsVoice(id: 'echo', name: 'Echo 男声', locale: 'cloud'),
    TtsVoice(id: 'fable', name: 'Fable 叙述', locale: 'cloud'),
    TtsVoice(id: 'onyx', name: 'Onyx 低沉', locale: 'cloud'),
    TtsVoice(id: 'nova', name: 'Nova 女声', locale: 'cloud'),
    TtsVoice(id: 'shimmer', name: 'Shimmer 柔和', locale: 'cloud'),
  ];

  @override
  Future<void> setVoice(String voiceId) async {
    if (voiceId.isNotEmpty) _voice = voiceId;
  }

  @override
  Future<void> setRate(double rate) async => _rate = rate;

  @override
  Future<void> setPitch(double pitch) async {
    // 接口本身没有音调参数，用播放器侧变调实现
    try {
      await _player.setPitch(pitch);
    } catch (_) {
      // 部分平台不支持变调，忽略
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed) throw StateError('云端 TTS 引擎已释放');
    if (!isAvailable) {
      throw StateError('云端 TTS 未配置：请在「设置 → 云端 TTS 配置」中填写接口地址与 API Key');
    }
    if (text.trim().isEmpty) return;

    final bytes = await _synthesize(text);
    final done = Completer<void>();
    _pending = done;
    StreamSubscription<ProcessingState>? subscription;
    try {
      await _player.setAudioSource(_BytesAudioSource(bytes));
      subscription = _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed && !done.isCompleted) done.complete();
      });
      unawaited(_player.play());
      await done.future;
    } finally {
      await subscription?.cancel();
      if (identical(_pending, done)) _pending = null;
      if (!done.isCompleted) done.complete();
    }
    _onComplete?.call();
  }

  /// 请求云端合成，返回音频字节；失败抛异常（由调度层降级处理）
  Future<Uint8List> _synthesize(String text) async {
    final response = await _client
        .post(
          _endpoint,
          headers: <String, String>{
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
          },
          body: jsonEncode(<String, dynamic>{
            'model': 'tts-1',
            'input': text,
            'voice': _voice,
            'speed': _rate,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw CloudTtsException(
        '云端 TTS 返回 ${response.statusCode}：${_brief(response.body)}',
      );
    }
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) throw CloudTtsException('云端 TTS 返回了空音频');
    return bytes;
  }

  static String _brief(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }

  @override
  Future<void> pause() async {
    _completePending();
    try {
      await _player.pause();
    } catch (_) {
      // 忽略暂停异常
    }
  }

  @override
  Future<void> stop() async {
    _completePending();
    try {
      await _player.stop();
    } catch (_) {
      // 忽略停止异常
    }
  }

  void _completePending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  void setCompletionHandler(void Function()? handler) => _onComplete = handler;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onComplete = null;
    await stop();
    await _player.dispose();
    _client.close();
  }
}

/// 简单的云端异常类型，便于上层识别并降级
class CloudTtsException implements Exception {
  CloudTtsException(this.message);

  final String message;

  @override
  String toString() => message;
}
