import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'pages/home_page.dart';
import 'pages/speak_now_page.dart';
import 'services/c2s.dart';
import 'services/crash_log.dart';
import 'services/document_service.dart';
import 'services/download_watcher.dart';
import 'services/speak_intake.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';
import 'tts/media_interruption.dart';
import 'tts/tts_audio_handler.dart';
import 'tts/tts_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 兜底：任何未捕获异常都落盘（logcat 重启就没，文件能留下来）
  await CrashLog.install();
  CrashLog.mark('main() 开始');
  // 本地设置（文档库、TTS 配置、主题）与朗读调度中心
  await StorageService.instance.init();
  await TtsManager.instance.init();
  // 解析缓存目录先求出来：等第一次打开文档时，用户正等着解析出结果，
  // 那时再做平台通道往返等于把耗时直接加到首屏（见 DocumentService.warmUpCacheDirectory）
  await DocumentService.warmUpCacheDirectory();
  CrashLog.mark('存储与朗读管理器初始化完成');
  // 下载器必须在 runApp 之前初始化（仅 Android / iOS 支持，其它平台忽略）
  try {
    await FlutterDownloader.initialize(debug: false);
  } catch (_) {
    // 桌面 / Web 无对应实现，忽略
  }
  // 后台朗读 + 通知栏控制：注册前台服务与媒体通知
  await TtsAudioHandler.init();
  // 音频属性 + 打断监听：**必须在这里单独做一次**，不能只靠 init() 里那句 ——
  // 桌面 / 测试环境里 audio_service 会初始化失败，那时也要按当前设置
  // （是否允许其它媒体打断）把音频会话配好，否则开关形同虚设。
  await MediaInterruptionController.instance.applySettings();
  // 外部文本入口（分享 / 划词 / 打开文本 / C2S）：冷启动携带的文本在这里取走
  await SpeakIntake.instance.init();
  // 复制即朗读：读一次配置；开关开着但悬浮球没跑起来时补拉一次
  // （同时兜住「开机自启被系统拦掉」的情况：打开一次应用就恢复）
  unawaited(C2sController.instance.bootstrap());
  CrashLog.mark('音频服务与外部文本入口初始化完成，准备 runApp');
  runApp(const TtsReaderApp());
  // 后台下载收尾扫描（v1.21.40）：用户可能在浏览器页发起下载后就退到桌面 /
  // 杀掉应用 —— 那时页面前台轮询已经停了，下载跑完不会入库。
  // 启动时扫一遍，配合回前台那一次（见 didChangeAppLifecycleState）。
  unawaited(DownloadWatcher.instance.sweep());
}

/// 桃花源阅读器：Material 3 + 动态取色种子 0xFF6750A4，支持亮 / 暗色
class TtsReaderApp extends StatefulWidget {
  const TtsReaderApp({super.key});

  /// Material 3 种子色
  static const Color seedColor = Color(0xFF6750A4);

  @override
  State<TtsReaderApp> createState() => _TtsReaderAppState();
}

class _TtsReaderAppState extends State<TtsReaderApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<SpeakRequest>? _subscription;

  /// Navigator 还没就绪时的重试次数（避免每帧空转）
  int _pendingRetries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 外部文本（分享 / 划词 / C2S）一进来就打开即读页并开始朗读
    _subscription = SpeakIntake.instance.stream.listen(_openSpeakNow);
    // 冷启动时文本可能已经躺在原生侧，首帧后再取一次（拿不到就算了）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final SpeakRequest? pending = SpeakIntake.instance.takePending();
      if (pending != null) {
        _openSpeakNow(pending);
      } else {
        unawaited(SpeakIntake.instance.pullPending());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 引擎比 Activity 活得久（audio_service 常驻）时，新 intent 只能靠回前台时来取
    if (state == AppLifecycleState.resumed) {
      unawaited(SpeakIntake.instance.pullPending());
      // 后台下载收尾扫描（v1.21.40）：用户是"切出去等下载"，回来时正好在这里补上
      // —— 页面前台轮询在他切走那一刻就停了。
      unawaited(DownloadWatcher.instance.sweep());
    }
  }

  /// 打开即读页；带文本的外部入口自动开始朗读
  void _openSpeakNow(SpeakRequest request) {
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) {
      // 首帧之前还没有 Navigator：等下一帧再试（最多几次，避免空转）
      if (_pendingRetries < 10) {
        _pendingRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) => _openSpeakNow(request));
      }
      return;
    }
    _pendingRetries = 0;
    CrashLog.mark('外部文本入口：${request.source.label}，${request.text.length} 字');
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SpeakNowPage(
          initialText: request.text,
          source: request.source,
          autoSpeak: true,
          fromExternalApp: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storage = StorageService.instance;
    return ChangeNotifierProvider<TtsManager>.value(
      value: TtsManager.instance,
      // 主题模式 / 取色来源 / 背景图 任一变化都要重建（外观设置是三个独立的通知源）
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: storage.themeMode,
        builder: (context, mode, _) => ValueListenableBuilder<int>(
          valueListenable: storage.appearance,
          builder: (context, _, __) => AppTheme.build(
            builder: (light, dark) => MaterialApp(
              title: '桃花源阅读器',
              debugShowCheckedModeBanner: false,
              navigatorKey: _navigatorKey,
              themeMode: mode,
              theme: light,
              darkTheme: dark,
              // 自定义背景图铺在所有界面下面（页面背景已设为透明）
              builder: (context, child) => AppTheme.backgroundLayer(
                context: context,
                child: child ?? const SizedBox.shrink(),
              ),
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
              home: const HomePage(),
            ),
          ),
        ),
      ),
    );
  }
}
