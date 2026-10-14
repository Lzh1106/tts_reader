package com.example.tts_reader

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * MP3 编码器（LAME）的 Kotlin 门面（★v1.21.45 改动 5）。
 *
 * ## 为什么要有这一层
 *
 * 朗读音频导出现在默认出 MP3：`flutter_tts.synthesizeToFile` 只能吐 **WAV**
 * （一本 30 万字的书几百 MB），转 MP3 必须有编码器 —— Android 平台自带的是
 * AAC 编码器（MediaCodec），**没有 MP3 编码器**，所以内置 LAME。
 *
 * ## 架构
 *
 * ```
 * Dart(AudioExporter) → MethodChannel tts_reader/lame
 *                      → LameChannel(本文件)
 *                      → LameEncoder.encodeWavToMp3()   ← JNI
 *                      → liblame.so（LAME 3.100 核心 + cpp/lame_jni.c）
 * ```
 *
 * ## 失败策略（重要）
 *
 * 这一层**任何情况都不抛异常**，只返回 false —— Dart 侧据此**回退到 WAV**：
 * 宁可给用户一个大文件，也不能因为编码器出问题让导出直接失败。
 * 所以 `System.loadLibrary` 也放在 try/catch 里（库缺失 / ABI 不匹配时
 * 只是"没有 MP3"，不是崩溃）。
 */
object LameEncoder {

    private const val TAG = "TTS_LAME"

    /** 库加载状态：null = 还没试过，true/false = 试过了 */
    @Volatile
    private var loaded: Boolean? = null

    private fun ensureLoaded(): Boolean {
        loaded?.let { return it }
        synchronized(this) {
            loaded?.let { return it }
            val ok = try {
                System.loadLibrary("lame")
                true
            } catch (t: Throwable) {
                Log.e(TAG, "loadLibrary(lame) 失败：${t.message}")
                false
            }
            loaded = ok
            return ok
        }
    }

    /** JNI 实现（见 cpp/lame_jni.c）。符号用 RegisterNatives 显式绑定，不依赖名字修饰。 */
    private external fun encodeWavToMp3(wavPath: String, mp3Path: String, bitrate: Int): Boolean

    private external fun lameVersion(): String

    /** 库能不能用（Dart 侧可以先问一句，避免白跑一趟） */
    fun available(): Boolean = ensureLoaded()

    /** LAME 版本号（诊断用；失败返回空串） */
    fun version(): String = try {
        if (ensureLoaded()) lameVersion() else ""
    } catch (t: Throwable) {
        Log.e(TAG, "lameVersion 失败：${t.message}")
        ""
    }

    /**
     * WAV → MP3。成功 true；**任何失败都 false**（绝不抛异常）。
     *
     * @param wavPath 源 WAV（flutter_tts 生成的临时文件）
     * @param mp3Path 目标 MP3
     * @param bitrate kbps（<=0 时用 64）
     */
    fun encode(wavPath: String, mp3Path: String, bitrate: Int): Boolean {
        if (!ensureLoaded()) return false
        val wav = File(wavPath)
        if (!wav.isFile || wav.length() <= 44L) { // 44 = 最小 WAV 头
            Log.e(TAG, "源文件不像 WAV：$wavPath")
            return false
        }
        return try {
            val ok = encodeWavToMp3(wavPath, mp3Path, if (bitrate > 0) bitrate else 64)
            if (!ok) {
                // 失败时清掉半成品：不留一个 0 字节 / 半截的 mp3 给用户
                val out = File(mp3Path)
                if (out.isFile) out.delete()
            }
            ok
        } catch (t: Throwable) {
            Log.e(TAG, "encode 异常：${t.message}")
            false
        }
    }
}

/**
 * `tts_reader/lame` 平台通道（与 C2sChannel / KeepAlive / FolderChannel 同款写法）。
 *
 * 方法：
 * * `encode`：参数 `{wavPath, mp3Path, bitrate}` → 返回 Boolean（失败不抛异常）
 * * `version`：返回 LAME 版本号（诊断）
 * * `available`：返回库是否可用
 */
object LameChannel {

    const val NAME = "tts_reader/lame"

    private const val TAG = "TTS_LAME"

    /** 通道只挂一次：Activity 重建时重复 attach 会让同一个 handler 被注册两遍 */
    @Volatile
    private var attached = false

    fun attach(messenger: BinaryMessenger) {
        if (attached) return
        attached = true
        val channel = MethodChannel(messenger, NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "encode" -> {
                    val wav = call.argument<String>("wavPath")
                    val mp3 = call.argument<String>("mp3Path")
                    val bitrate = call.argument<Int>("bitrate") ?: 64
                    if (wav.isNullOrBlank() || mp3.isNullOrBlank()) {
                        Log.e(TAG, "encode 参数缺失：wav=$wav mp3=$mp3")
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    // 编码是纯 CPU 活，放主线程会把界面卡住（一章 2~3 秒）
                    Thread {
                        val ok = LameEncoder.encode(wav, mp3, bitrate)
                        Log.i(TAG, "encode 完成：$ok（${File(wav).length()} 字节 → ${File(mp3).length()} 字节）")
                        Handler_?.post { result.success(ok) }
                    }.start()
                }
                "version" -> result.success(LameEncoder.version())
                "available" -> result.success(LameEncoder.available())
                // 公共「音乐」目录的绝对路径：flutter_tts 的 synthesizeToFile 把 WAV 写在那里，
                // 我们要在同一目录里把 MP3 写出来（同目录改名最省事，也不用跨卷拷贝）
                "musicDir" -> result.success(musicDir())
                else -> result.notImplemented()
            }
        }
    }

    /** `/storage/emulated/0/Music`（外置存储不可用时返回 app 的私有外部目录） */
    private fun musicDir(): String {
        return try {
            val dir = android.os.Environment
                .getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_MUSIC)
            if (dir != null && (dir.exists() || dir.mkdirs())) dir.absolutePath else ""
        } catch (t: Throwable) {
            Log.e(TAG, "取音乐目录失败：${t.message}")
            ""
        }
    }

    /**
     * 主线程 Handler。
     *
     * ⚠️ 名字故意不叫 `Handler`（那是 android.os.Handler 的类名，会遮蔽 imports）；
     * 而 `MethodChannel.Result` **必须在主线程回调**，否则 Flutter 侧收不到。
     */
    private val Handler_ = android.os.Handler(android.os.Looper.getMainLooper())
}
