import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/services/audio_export.dart';
import 'package:tts_reader/services/lame_encoder.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/services/text_processor.dart';
import 'package:tts_reader/tts/system_tts_synthesizer.dart';

/// 导出朗读音频（T2S 的「导出为音频文件」）验证：
/// 分片不丢字、文件名安全、失败不中断、可取消，
/// 以及「插件永不回复」时不会把整次导出挂死（这是本工程踩过的老坑）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StorageService.instance.resetForTest();
    TextProcessor.instance.resetForTest();
    await StorageService.instance.init();
    await TextProcessor.instance.init();
  });

  group('文本切片', () {
    test('短文本不切', () {
      expect(AudioExporter.splitText('短短一句话。'), <String>['短短一句话。']);
    });

    test('按句切片且不丢字', () {
      final sentences = List<String>.generate(30, (i) => '这是第 $i 句话，用来测试切片。');
      final text = sentences.join();
      final parts = AudioExporter.splitText(text, maxLength: 60);
      expect(parts.length, greaterThan(1));
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(60));
      }
      expect(parts.join(), text, reason: '切片之后拼起来必须与原文逐字一致');
    });

    test('单句超过上限时硬切，不整句丢弃', () {
      final long = '甲' * 500;
      final parts = AudioExporter.splitText(long, maxLength: 100);
      expect(parts.length, 5);
      expect(parts.join(), long);
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(100));
      }
    });

    test('空文本切出空列表', () {
      expect(AudioExporter.splitText('   \n  '), isEmpty);
    });

    test('换行也当作切分点（整页 / 整章文本）', () {
      final parts = AudioExporter.splitText('第一段\n第二段\n第三段', maxLength: 8);
      expect(parts.join().replaceAll('\n', ''), '第一段第二段第三段');
      expect(parts.length, greaterThan(1));
    });
  });

  group('文件名', () {
    test('非法字符被替换，路径分隔符不会漏出去', () {
      final name = AudioExporter.sanitize('a/b\\c:d*e?f"g<h>i|j');
      expect(name.contains('/'), isFalse);
      expect(name.contains('\\'), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains('*'), isFalse);
      expect(name, 'a_b_c_d_e_f_g_h_i_j');
    });

    test('过长截断、空名兜底、结尾点号去掉', () {
      expect(AudioExporter.sanitize('书' * 100).length, AudioExporter.maxBaseLength);
      expect(AudioExporter.sanitize('   '), '朗读音频');
      expect(AudioExporter.sanitize('书名...'), '书名');
    });

    test('计划里的序号补零，保证按文件名排序就是播放顺序', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '第一句。第二句。')],
        baseName: '测试书',
        maxPartLength: 4,
      );
      expect(plan.parts.map((part) => part.fileName).toList(), <String>[
        '测试书-001.wav',
        '测试书-002.wav',
      ]);
      expect(plan.parts.every((part) => part.chapterTitle == '第一章'), isTrue);
    });

    test('多章连续编号，章信息跟着走', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。'), ('第二章', '乙。'), ('第三章', '')],
        baseName: 'book',
      );
      expect(plan.parts.length, 2, reason: '空章不产生文件');
      expect(plan.parts[0].index, 1);
      expect(plan.parts[0].chapterIndex, 0);
      expect(plan.parts[1].index, 2);
      expect(plan.parts[1].chapterIndex, 1);
    });

    test('播放列表按顺序列出文件', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。乙。丙。')],
        baseName: 'book',
        maxPartLength: 2,
      );
      final playlist = plan.toPlaylist();
      expect(playlist.startsWith('#EXTM3U'), isTrue);
      for (final part in plan.parts) {
        expect(playlist, contains(part.fileName));
      }
      // 顺序必须与 parts 一致
      var cursor = 0;
      for (final part in plan.parts) {
        final at = playlist.indexOf(part.fileName, cursor);
        expect(at, greaterThanOrEqualTo(cursor), reason: '文件名出现顺序要与分片顺序一致');
        cursor = at;
      }
    });
  });

  group('执行导出', () {
    test('全部成功：按顺序记录文件名并回报进度', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。乙。丙。')],
        baseName: 'book',
        maxPartLength: 2,
      );
      final calls = <String>[];
      final progress = <double>[];
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async {
          calls.add('$fileName|$text');
          return true;
        },
        onProgress: (value) => progress.add(value.fraction),
      );

      expect(report.files.length, plan.parts.length);
      expect(report.failed, isEmpty);
      expect(report.cancelled, isFalse);
      expect(calls.length, plan.parts.length);
      expect(progress.last, 1.0);
      expect(progress, orderedEquals(<double>[for (var i = 1; i <= plan.parts.length; i++) i / plan.parts.length]));
    });

    test('单片失败不中断整次导出', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。乙。丙。丁。')],
        baseName: 'book',
        maxPartLength: 2,
      );
      var index = 0;
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async => ++index != 2, // 第二片失败
      );
      expect(report.files.length, plan.parts.length - 1);
      expect(report.failed, <String>[plan.parts[1].fileName]);
      expect(report.hasFailure, isTrue);
    });

    test('合成抛异常按失败处理，不冒泡', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。')],
        baseName: 'book',
      );
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async => throw StateError('引擎挂了'),
      );
      expect(report.files, isEmpty);
      expect(report.failed, <String>['book-001.wav']);
    });

    test('取消后立即收尾，已生成的文件保留', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '甲。乙。丙。丁。戊。')],
        baseName: 'book',
        maxPartLength: 2,
      );
      var done = 0;
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async {
          done++;
          return true;
        },
        isCancelled: () => done >= 2,
      );
      expect(report.cancelled, isTrue);
      expect(report.files.length, 2);
      expect(done, 2, reason: '取消之后不能再继续合成');
    });

    test('空计划直接返回空报告', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '   ')],
        baseName: 'book',
      );
      expect(plan.isEmpty, isTrue);
      final report = await AudioExporter.run(plan, synth: (text, fileName) async => true);
      expect(report.files, isEmpty);
      expect(report.cancelled, isFalse);
    });
  });

  group('与朗读设置一致', () {
    test('导出用的是预处理之后的文本（听感与播放一致）', () async {
      // 默认规则里有「△ 读成三角形」，导出的音频也应当是处理后的文本
      final processed = TextProcessor.instance.apply('△ 表示三角形。');
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', processed)],
        baseName: 'book',
      );
      final spoken = <String>[];
      await AudioExporter.run(
        plan,
        synth: (text, fileName) async {
          spoken.add(text);
          return true;
        },
      );
      expect(spoken.join(), isNot(contains('△')));
      expect(spoken.join(), contains('三角形'));
    });
  });

  group('插件不回复时的兜底', () {
    test('bounded：操作永不完成时会超时返回 false，而不是挂住', () async {
      final never = Completer<void>();
      final started = DateTime.now();
      final ok = await SystemTtsSynthesizer.bounded(
        () => never.future,
        const Duration(milliseconds: 60),
      );
      expect(ok, isFalse);
      expect(DateTime.now().difference(started).inMilliseconds, greaterThanOrEqualTo(50));
    });

    test('bounded：操作很快完成时返回 true，且不留悬挂定时器', () async {
      final ok = await SystemTtsSynthesizer.bounded(
        () async => Future<void>.delayed(const Duration(milliseconds: 5)),
        const Duration(seconds: 5),
      );
      expect(ok, isTrue);
    });

    test('bounded：操作抛异常按失败处理，不冒泡', () async {
      final ok = await SystemTtsSynthesizer.bounded(
        () async => throw StateError('合成失败'),
        const Duration(seconds: 5),
      );
      expect(ok, isFalse);
    });
  });

  // ── ★v1.21.45 改动 5：导出格式（MP3 / WAV） ─────────────────────────
  group('导出格式与 MP3 转换', () {
    test('★文件名后缀跟着格式走（默认 mp3）', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '第一句。第二句。')],
        baseName: 'book',
        extension: AudioExportFormat.mp3.extension,
      );
      expect(plan.parts.single.fileName, 'book-001.mp3');
      // 合成时**永远先用 WAV**（系统 TTS 只能吐 WAV），文件名由它推出来
      expect(plan.parts.single.wavFileName, 'book-001.wav');
    });

    test('选 WAV 时后缀是 .wav（保留无损这条路）', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '第一句。')],
        baseName: 'book',
        extension: AudioExportFormat.wav.extension,
      );
      expect(plan.parts.single.fileName, 'book-001.wav');
      expect(plan.parts.single.wavFileName, 'book-001.wav');
    });

    test('★播放列表（m3u）里的后缀随格式变', () {
      final chapters = <(String, String)>[('第一章', '第一句。第二句。')];
      final mp3 = AudioExporter.plan(
        chapters: chapters,
        baseName: 'book',
        extension: AudioExportFormat.mp3.extension,
      );
      final wav = AudioExporter.plan(
        chapters: chapters,
        baseName: 'book',
        extension: AudioExportFormat.wav.extension,
      );
      expect(mp3.toPlaylist(), contains('book-001.mp3'));
      expect(mp3.toPlaylist(), isNot(contains('.wav')));
      expect(wav.toPlaylist(), contains('book-001.wav'));
      expect(wav.toPlaylist(), isNot(contains('.mp3')));
    });

    test('★带点的 extension 也能吃（".mp3" 与 "mp3" 等价）', () {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '句子。')],
        baseName: 'book',
        extension: '.mp3',
      );
      expect(plan.parts.single.fileName, 'book-001.mp3');
    });

    test('★转换成功：产物记 MP3，且合成时用的是 WAV 名字', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '句子。')],
        baseName: 'book',
        extension: AudioExportFormat.mp3.extension,
      );
      final synthNames = <String>[];
      final convertCalls = <String>[];
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async {
          synthNames.add(fileName);
          return true;
        },
        convert: (part) async {
          convertCalls.add(part.fileName);
          return true;
        },
      );
      expect(synthNames, <String>['book-001.wav'],
          reason: '★系统 TTS 只能吐 WAV —— 合成阶段必须用 .wav 名字');
      expect(convertCalls, <String>['book-001.mp3']);
      expect(report.files, <String>['book-001.mp3']);
      expect(report.failed, isEmpty);
    });

    test('★转换失败：**回退到 WAV**（文件还在，不算失败）', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '句子。')],
        baseName: 'book',
        extension: AudioExportFormat.mp3.extension,
      );
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async => true,
        convert: (part) async => false, // 模拟 LAME 通道失败
      );
      expect(report.files, <String>['book-001.wav'],
          reason: '★转不成 MP3 不能丢掉这次导出：用户手里得有一份能听的文件');
      expect(report.failed, isEmpty, reason: '这不是"失败"，是降级');
    });

    test('★转换抛异常也按失败处理（照样留住 WAV）', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '句子。')],
        baseName: 'book',
        extension: AudioExportFormat.mp3.extension,
      );
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async => true,
        convert: (part) async => throw StateError('原生崩了'),
      );
      expect(report.files, <String>['book-001.wav']);
      expect(report.failed, isEmpty);
    });

    test('不传 convert（选 WAV）时：合成与产物都是 .wav，不碰转换', () async {
      final plan = AudioExporter.plan(
        chapters: <(String, String)>[('第一章', '句子。')],
        baseName: 'book',
        extension: AudioExportFormat.wav.extension,
      );
      final synthNames = <String>[];
      final report = await AudioExporter.run(
        plan,
        synth: (text, fileName) async {
          synthNames.add(fileName);
          return true;
        },
      );
      expect(synthNames, <String>['book-001.wav']);
      expect(report.files, <String>['book-001.wav']);
    });

    test('设置项：默认 mp3、能落盘读回、坏数据回默认', () async {
      expect(StorageService.instance.audioExportFormat, AudioExportFormat.mp3,
          reason: '★默认必须是 MP3（用户明确要求：默认 MP3、保留 WAV）');

      await StorageService.instance.setAudioExportFormat(AudioExportFormat.wav);
      StorageService.instance.resetForTest();
      await StorageService.instance.init();
      expect(StorageService.instance.audioExportFormat, AudioExportFormat.wav,
          reason: '重启后要记住上次选的格式');

      // 坏数据不许崩，回默认
      expect(AudioExportFormat.fromName('flac'), AudioExportFormat.mp3);
      expect(AudioExportFormat.fromName(null), AudioExportFormat.mp3);
      expect(AudioExportFormat.fromName('wav'), AudioExportFormat.wav);
    });

    test('★LameEncoder：非 Android / 通道异常一律返回 false（不抛给用户）', () async {
      // 测试环境（桌面）没有原生库 —— 必须"安静地失败"
      final ok = await LameEncoder.encode(
        wavPath: '/tmp/a.wav',
        mp3Path: '/tmp/a.mp3',
      );
      expect(ok, isFalse);
      expect(LameEncoder.lastError, isNotEmpty, reason: '要留下原因，便于诊断');

      // 测试开关：直接给出结论，不碰平台通道
      LameEncoder.debugEncodeOverride = true;
      addTearDown(() => LameEncoder.debugEncodeOverride = null);
      expect(
        await LameEncoder.encode(wavPath: '/tmp/a.wav', mp3Path: '/tmp/a.mp3'),
        isTrue,
      );
    });

    test('★LameEncoder：拿不到音乐目录时明确回退（不尝试转换）', () async {
      LameEncoder.debugMusicDirOverride = '';
      addTearDown(() => LameEncoder.debugMusicDirOverride = null);
      final ok = await LameEncoder.convertInMusicDir(
        wavFileName: 'book-001.wav',
        mp3FileName: 'book-001.mp3',
      );
      expect(ok, isFalse);
      expect(LameEncoder.lastError, contains('音乐目录'));
    });
  });
}
