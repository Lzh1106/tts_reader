package com.example.tts_reader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 后台朗读保活（`tts_reader/power`）：熄屏之后朗读不中断。
 *
 * 为什么需要它：
 * - `wakelock_plus` 在 Android 上加的是 `FLAG_KEEP_SCREEN_ON`（**屏幕常亮**），
 *   与「熄屏继续读」正好相反，而且很费电；
 * - 真正要的是 `PARTIAL_WAKE_LOCK`：屏幕可以关，CPU 继续跑；
 * - 云端 TTS 还要边下边播，屏幕关掉后 Wi-Fi 可能被挂起，所以再配一个 WifiLock。
 *
 * 前台服务由 audio_service 负责（媒体通知常驻），这里只解决 CPU / 网络不被挂起。
 * 锁只在「正在朗读且未暂停」期间持有，暂停或停止立刻释放，避免待机耗电。
 */
object KeepAlive {

    const val NAME = "tts_reader/power"
    private const val TAG = "TTSReader"

    /** 唤醒锁标签（系统电池统计里能看到） */
    private const val WAKE_TAG = "tts_reader:reading"
    private const val WIFI_TAG = "tts_reader:cloud-tts"

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        val channel = MethodChannel(messenger, NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    acquire(appContext)
                    result.success(held())
                }

                "release" -> {
                    release()
                    result.success(false)
                }

                "isHeld" -> result.success(held())

                "status" -> result.success(status(appContext))

                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations(appContext)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    /** 拿锁：正在朗读期间调用（重复调用无害） */
    fun acquire(context: Context) {
        try {
            val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (power != null) {
                if (wakeLock == null) {
                    wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
                        setReferenceCounted(false)
                    }
                }
                val lock = wakeLock
                if (lock != null && !lock.isHeld) {
                    lock.acquire()
                    Log.i(TAG, "熄屏保活：已持有 CPU 唤醒锁")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "获取唤醒锁失败：$e")
        }

        try {
            val wifi = context.getApplicationContext()
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifi != null) {
                if (wifiLock == null) {
                    wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, WIFI_TAG).apply {
                        setReferenceCounted(false)
                    }
                }
                val lock = wifiLock
                if (lock != null && !lock.isHeld) lock.acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "获取 WifiLock 失败：$e")
        }
    }

    /** 放锁：暂停 / 停止 / 读完时调用 */
    fun release() {
        try {
            val lock = wakeLock
            if (lock != null && lock.isHeld) {
                lock.release()
                Log.i(TAG, "熄屏保活：已释放 CPU 唤醒锁")
            }
        } catch (e: Exception) {
            Log.w(TAG, "释放唤醒锁失败：$e")
        }
        try {
            val lock = wifiLock
            if (lock != null && lock.isHeld) lock.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 WifiLock 失败：$e")
        }
    }

    fun held(): Boolean = wakeLock?.isHeld == true

    /** 设置页要的状态汇总 */
    private fun status(context: Context): Map<String, Any?> {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && power != null) {
            power.isIgnoringBatteryOptimizations(context.packageName)
        } else {
            true
        }
        return mapOf(
            "held" to held(),
            "wifiHeld" to (wifiLock?.isHeld == true),
            "ignoringBatteryOptimizations" to ignoring,
            "interactive" to (power?.isInteractive ?: true),
            "sdkInt" to Build.VERSION.SDK_INT
        )
    }

    /**
     * 跳系统对话框申请「忽略电池优化」
     *
     * 国产 ROM 通常还有自己的「后台运行 / 自启动」开关，这里只能把标准入口给出来。
     */
    private fun requestIgnoreBatteryOptimizations(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val packageUri = Uri.parse("package:" + context.packageName)
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(direct)
            return
        } catch (_: Exception) {
            // 部分 ROM 没有这个入口，退到电池优化列表页
        }
        try {
            context.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            C2s.toast(context, "请到系统设置的电池选项里允许本应用后台运行")
        }
    }
}
