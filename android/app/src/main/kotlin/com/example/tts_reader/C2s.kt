package com.example.tts_reader

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.widget.Toast

/**
 * 复制即朗读（C2S，对应 T2S 的 copy2speak 模块）的公共设施。
 *
 * 包含三件事：
 * - 配置项（开关、复制后自动弹出悬浮球、悬浮球大小与位置）存 SharedPreferences，
 *   由 Flutter 侧通过 `tts_reader/c2s` 通道读写；
 * - 悬浮球 / 快捷磁贴拿到文本后统一走 [speak] 交给 Flutter 朗读；
 * - 悬浮窗权限与剪贴板这两个平台相关的细节收在这里。
 */
object C2s {

    /** 日志标签（排查复制即朗读问题时用：adb logcat -s C2S） */
    const val TAG = "C2S"

    const val PREFS = "c2s"
    const val KEY_ENABLED = "enabled"
    const val KEY_AUTO_SHOW = "autoShow"
    const val KEY_SIZE = "sizeDp"
    const val KEY_X = "x"
    const val KEY_Y = "y"

    /** 悬浮球默认直径（dp） */
    const val DEFAULT_SIZE_DP = 52

    /** 悬浮球直径范围（dp），与设置页的滑块一致 */
    const val MIN_SIZE_DP = 40
    const val MAX_SIZE_DP = 72

    /** 交给 Flutter 的文本长度上限（与 Dart 侧 SpeakIntake.maxTextLength 对应） */
    private const val MAX_CHARS = 100000

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, value: Boolean) =
        prefs(context).edit().putBoolean(KEY_ENABLED, value).apply()

    /** 复制文本后是否自动把悬浮球弹出来（T2S 的 "pop up a floating speak button after you copy"） */
    fun autoShow(context: Context): Boolean = prefs(context).getBoolean(KEY_AUTO_SHOW, true)

    fun setAutoShow(context: Context, value: Boolean) =
        prefs(context).edit().putBoolean(KEY_AUTO_SHOW, value).apply()

    fun sizeDp(context: Context): Int =
        prefs(context).getInt(KEY_SIZE, DEFAULT_SIZE_DP).coerceIn(MIN_SIZE_DP, MAX_SIZE_DP)

    fun setSizeDp(context: Context, value: Int) = prefs(context)
        .edit()
        .putInt(KEY_SIZE, value.coerceIn(MIN_SIZE_DP, MAX_SIZE_DP))
        .apply()

    /** 悬浮球上次停留的位置（-1 表示还没拖过，用默认位置） */
    fun position(context: Context): Pair<Int, Int> =
        prefs(context).getInt(KEY_X, -1) to prefs(context).getInt(KEY_Y, -1)

    fun setPosition(context: Context, x: Int, y: Int) =
        prefs(context).edit().putInt(KEY_X, x).putInt(KEY_Y, y).apply()

    // ---------------- 权限 ----------------

    /** 是否能显示悬浮窗；Android 6 以下是安装即得 */
    fun canDrawOverlay(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Settings.canDrawOverlays(context) else true

    /** 跳到系统的「显示在其他应用上层」授权页 */
    fun requestOverlayPermission(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:" + context.packageName)
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // 个别 ROM 没有这个页面：忽略，让用户自己到系统设置里开
        }
    }

    // ---------------- 剪贴板 ----------------

    /**
     * 读当前剪贴板文本。
     *
     * Android 10 起，后台应用读剪贴板只会拿到 null，必须由**有焦点的界面**来读，
     * 所以悬浮球与磁贴都走 [ClipboardSpeakActivity]（透明的取词界面）。
     */
    @Suppress("DEPRECATION")
    fun readClipboard(context: Context): String {
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return ""
        val clip = try {
            manager.primaryClip
        } catch (_: Exception) {
            null
        } ?: return ""
        if (clip.itemCount <= 0) return ""
        val text = try {
            clip.getItemAt(0).coerceToText(context)?.toString()
        } catch (_: Exception) {
            null
        }
        return text?.trim().orEmpty()
    }

    // ---------------- 交付给 Flutter ----------------

    /**
     * 把文本交给 Flutter 侧朗读。
     *
     * 引擎还在跑（audio_service 让引擎常驻）就直接推过去，不打断用户当前在做的事；
     * 引擎已经没了才把界面拉起来，由冷启动路径取走这段文本。
     */
    fun speak(context: Context, text: String, source: String = "c2s") {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val payload = mapOf(
            "text" to if (trimmed.length > MAX_CHARS) trimmed.substring(0, MAX_CHARS) else trimmed,
            "source" to source
        )
        if (MainActivity.deliver(payload)) {
            Log.i(TAG, "已把 ${trimmed.length} 字交给 Flutter 朗读（source=$source）")
            return
        }

        Log.i(TAG, "Flutter 引擎不在听，改为拉起界面（source=$source）")
        MainActivity.stash(payload)
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(MainActivity.EXTRA_TEXT, payload["text"] as String)
            putExtra(MainActivity.EXTRA_SOURCE, source)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // 后台启动 Activity 被系统拦截（少数 ROM）：文本还攒着，下次回到前台会读出来
            toast(context, "点一下桃花源阅读器即可朗读剪贴板内容")
        }
    }

    /** 读剪贴板并朗读；空剪贴板给一句提示 */
    fun speakClipboard(context: Context, source: String = "c2s") {
        val text = readClipboard(context)
        if (text.isEmpty()) {
            toast(context, "剪贴板里没有文本")
            return
        }
        speak(context, text, source)
    }

    fun toast(context: Context, message: String) {
        try {
            Toast.makeText(context.applicationContext, message, Toast.LENGTH_SHORT).show()
        } catch (_: Exception) {
            // 没有 Looper 等极端情况：提示发不出去就算了
        }
    }
}
