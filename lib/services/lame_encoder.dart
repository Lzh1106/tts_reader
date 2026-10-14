import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_log.dart';

/// 导出音频的格式（★v1.21.45 改动 5）
///
/// * [mp3]：默认。**小**（一本 30 万字的书从几百 MB 降到几十 MB），有损；
/// * [wav]：无损、体积大。保留它是因为"给耳朵留一条退路"——
///   万一某台机器上 LAME 跑不起来（原生库缺失 / 不是标准 WAV），用户还能出 WAV。
enum AudioExportFormat {
  mp3('MP3', 'mp3', '体积小（约为 WAV 的 1/10），日常听书够用'),
  wav('WAV', 'wav', '无损、体积大（30 万字的书可能几百 MB）');

  const AudioExportFormat(this.label, this.extension, this.hint);

  final String label;

  /// 文件扩展名（**不带点**）
  final String extension;

  /// 设置页 / 导出页上那句说明
  final String hint;

  /// 从设置里存下来的字符串解析；不认识就回默认（MP3）
  static AudioExportFormat fromName(Object? name) {
    if (name == wav.extension) return wav;
    if (name == mp3.extension) return mp3;
    return mp3; // 默认 MP3
  }
}

/// WAV → MP3 的原生编码器门面（`tts_reader/lame` 通道）
///
/// ## 失败一律回退，绝不抛给用户
///
/// 原生侧任何问题（库没打进包、ABI 不匹配、WAV 头不是标准的、
/// 磁盘满……）都只会让这里返回 `false` —— 调用方据此**保留 WAV**，
/// 用户的导出照常完成，只是文件大一点。所以这一层把
/// `MissingPluginException`（桌面 / 单测环境）也当"不可用"处理。
class LameEncoder {
  LameEncoder._();

  static const MethodChannel channel = MethodChannel('tts_reader/lame');

  /// 默认码率（kbps）：听书 64 足够（语音内容对码率不敏感，体积减半）
  static const int defaultBitrate = 64;

  /// 单元测试用：直接给出"编码成功 / 失败"，不碰平台通道
  @visibleForTesting
  static bool? debugEncodeOverride;

  /// 平台侧记录的最后一次失败原因（诊断用；测试也能读）
  static String lastError = '';

  /// 把 [wavPath] 转成 [mp3Path]。成功 `true`，任何失败 `false`。
  static Future<bool> encode({
    required String wavPath,
    required String mp3Path,
    int bitrate = defaultBitrate,
  }) async {
    final bool? forced = debugEncodeOverride;
    if (forced != null) return forced;

    // 桌面上没有这个通道（也没有 LAME）：直接当不可用，不打日志刷屏
    if (!Platform.isAndroid) {
      lastError = '非 Android 平台没有 MP3 编码器';
      return false;
    }
    try {
      final bool ok = await channel.invokeMethod<bool>('encode', <String, Object>{
            'wavPath': wavPath,
            'mp3Path': mp3Path,
            'bitrate': bitrate,
          }) ??
          false;
      if (!ok) {
        lastError = '原生编码返回 false';
        CrashLog.mark('导出音频：MP3 编码失败（$wavPath → $mp3Path），已回退 WAV');
      }
      return ok;
    } on MissingPluginException {
      lastError = '通道不存在（原生库没打进包？）';
      CrashLog.mark('导出音频：MP3 通道不可用（MissingPluginException），已回退 WAV');
      return false;
    } on PlatformException catch (e) {
      lastError = '${e.code}: ${e.message}';
      CrashLog.mark('导出音频：MP3 编码异常（${e.code}），已回退 WAV');
      return false;
    } catch (e) {
      lastError = '$e';
      CrashLog.mark('导出音频：MP3 编码意外错误（$e），已回退 WAV');
      return false;
    }
  }

  /// 原生库里的 LAME 版本号（诊断；拿不到返回空串）
  static Future<String> version() async {
    if (!Platform.isAndroid) return '';
    try {
      return await channel.invokeMethod<String>('version') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 公共「音乐」目录的绝对路径（拿不到返回空串）
  ///
  /// 为什么问原生要：`flutter_tts.synthesizeToFile` 把 WAV 写进公共「音乐」目录
  /// （Android 11+ 走 MediaStore，更早的版本直接写 `Environment.DIRECTORY_MUSIC`），
  /// 而 Dart 侧 **拿不到** 那个路径 —— 只有原生能给出权威值。
  static Future<String> musicDir() async {
    if (!Platform.isAndroid) return '';
    try {
      return await channel.invokeMethod<String>('musicDir') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 单元测试用：直接给出「音乐目录」，不碰平台通道
  @visibleForTesting
  static String? debugMusicDirOverride;

  /// 把「合成出来的 WAV」转成 MP3，并在成功后删掉 WAV。
  ///
  /// 返回 `true` 表示 MP3 **已经就位**；`false` 表示这次没转成 ——
  /// 调用方必须把 **WAV** 当成这次导出的产物（原文件我们**不删**）。
  static Future<bool> convertInMusicDir({
    required String wavFileName,
    required String mp3FileName,
    int bitrate = defaultBitrate,
  }) async {
    final String dir = debugMusicDirOverride ?? await musicDir();
    if (dir.isEmpty) {
      lastError = '拿不到音乐目录';
      CrashLog.mark('导出音频：拿不到音乐目录，MP3 转换跳过（保留 WAV）');
      return false;
    }
    final String wav = '$dir${Platform.pathSeparator}$wavFileName';
    final String mp3 = '$dir${Platform.pathSeparator}$mp3FileName';
    final bool ok = await encode(wavPath: wav, mp3Path: mp3, bitrate: bitrate);
    if (!ok) return false;
    // 转成功才删 WAV：失败时它**就是**这次的产物，删了用户就没文件了
    try {
      final file = File(wav);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      CrashLog.mark('导出音频：MP3 转好了，但删不掉临时 WAV（$e）');
    }
    return true;
  }
}
