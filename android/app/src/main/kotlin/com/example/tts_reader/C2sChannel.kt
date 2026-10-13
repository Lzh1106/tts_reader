package com.example.tts_reader

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 复制即朗读的设置通道（`tts_reader/c2s`）。
 *
 * Flutter 侧用它读写配置、申请悬浮窗权限、开关悬浮球，以及「朗读剪贴板」按钮。
 * 配置存在原生 SharedPreferences 里（服务与磁贴都要用，不能只放在 Dart 侧）。
 */
object C2sChannel {

    const val NAME = "tts_reader/c2s"

    /** 服务启动是异步的：回报状态前等这么久 */
    private const val SERVICE_SETTLE_MS = 400L

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(true)

                "getConfig" -> result.success(currentConfig(activity))

                /** 写入配置并按需启动 / 停止悬浮球，返回悬浮球**实际**是否在运行 */
                "apply" -> {
                    val map = call.arguments as? Map<*, *>
                    if (map != null) applyConfig(activity, map)
                    // 服务是异步起来的：立刻回报只会拿到「还没起来」，等一小会儿再看
                    Handler(Looper.getMainLooper()).postDelayed({
                        result.success(FloatingSpeakService.isRunning())
                    }, SERVICE_SETTLE_MS)
                }

                "hasOverlayPermission" -> result.success(C2s.canDrawOverlay(activity))

                "requestOverlayPermission" -> {
                    C2s.requestOverlayPermission(activity)
                    result.success(null)
                }

                "isRunning" -> result.success(FloatingSpeakService.isRunning())

                /** 界面里点「朗读剪贴板」：同样走透明界面取词，保证 Android 10+ 能读到 */
                "speakClipboard" -> {
                    ClipboardSpeakActivity.start(activity, "c2s")
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun currentConfig(activity: Activity): Map<String, Any?> = mapOf(
        "enabled" to C2s.isEnabled(activity),
        "autoShow" to C2s.autoShow(activity),
        "sizeDp" to C2s.sizeDp(activity),
        "running" to FloatingSpeakService.isRunning(),
        "overlayPermission" to C2s.canDrawOverlay(activity),
        "minSizeDp" to C2s.MIN_SIZE_DP,
        "maxSizeDp" to C2s.MAX_SIZE_DP
    )

    private fun applyConfig(activity: Activity, map: Map<*, *>) {
        (map["autoShow"] as? Boolean)?.let { C2s.setAutoShow(activity, it) }
        (map["sizeDp"] as? Number)?.let { C2s.setSizeDp(activity, it.toInt()) }
        val enabled = map["enabled"] as? Boolean ?: return
        C2s.setEnabled(activity, enabled)
        if (enabled) {
            FloatingSpeakService.start(activity)
        } else {
            FloatingSpeakService.stop(activity)
        }
    }
}
