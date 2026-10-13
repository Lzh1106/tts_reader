package com.example.tts_reader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.core.app.NotificationCompat
import kotlin.math.abs

/**
 * 复制即朗读的悬浮球（对应 T2S 的 `copy2speak.fsb` 悬浮按钮）。
 *
 * 行为：
 * - 常驻一个可拖动的小圆球，点一下读剪贴板、拖着走可以换位置（位置会记住）；
 * - 复制文本后（系统剪贴板变化）把球弹一下，提示「可以读了」；
 * - 用前台服务承载，避免进程被回收导致球突然消失；通知点开就是应用。
 *
 * 剪贴板内容必须由有焦点的界面来读（Android 10+ 的后台限制），
 * 所以点球之后是启动 [ClipboardSpeakActivity] 去取词，而不是在服务里直接读。
 */
class FloatingSpeakService : Service() {

    private var windowManager: WindowManager? = null
    private var button: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var clipboard: ClipboardManager? = null
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(C2s.TAG, "悬浮球服务启动：overlay=${C2s.canDrawOverlay(this)}")
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

        startForegroundSafely()

        if (!C2s.canDrawOverlay(this)) {
            // 没授权就没有可显示的东西，直接收摊（设置页会引导去授权）
            C2s.toast(this, "还没有「显示在其他应用上层」权限")
            stopSelf()
            return
        }
        addButton()
        registerClipboardListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PULSE) pulse()
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterClipboardListener()
        removeButton()
        if (instance === this) instance = null
        super.onDestroy()
    }

    // ---------------- 前台服务 ----------------

    private fun startForegroundSafely() {
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
            // Android 12+ 后台启动前台服务可能被拒；退化成普通服务，球照样显示
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "复制即朗读",
                    NotificationManager.IMPORTANCE_MIN
                )
                channel.description = "悬浮朗读按钮常驻提示"
                manager.createNotificationChannel(channel)
            }
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_speech)
            .setContentTitle("复制即朗读已开启")
            .setContentText("复制任意文字，点悬浮球即可朗读")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .build()
    }

    // ---------------- 悬浮球 ----------------

    private fun sizePx(): Int {
        val dp = C2s.sizeDp(this)
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    private fun addButton() {
        if (button != null) return
        val size = sizePx()
        val view = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#E66750A4"))
                setStroke(dp(2), Color.parseColor("#66FFFFFF"))
            }
            elevation = dp(6).toFloat()
        }
        val icon = ImageView(this).apply {
            setImageResource(R.drawable.ic_stat_speech)
            setColorFilter(Color.WHITE)
        }
        val iconSize = (size * 0.55f).toInt()
        view.addView(
            icon,
            FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER)
        )

        val layoutParams = WindowManager.LayoutParams(
            size,
            size,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val (savedX, savedY) = C2s.position(this@FloatingSpeakService)
            x = if (savedX >= 0) savedX else dp(12)
            y = if (savedY >= 0) savedY else dp(220)
        }

        attachTouch(view, layoutParams)
        try {
            windowManager?.addView(view, layoutParams)
        } catch (_: Exception) {
            C2s.toast(this, "悬浮球显示失败，请检查「显示在其他应用上层」权限")
            stopSelf()
            return
        }
        button = view
        params = layoutParams
    }

    /** 点击朗读、拖动换位置；松手后记住位置 */
    private fun attachTouch(view: View, layoutParams: WindowManager.LayoutParams) {
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var dragged = false

        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = layoutParams.x
                    startY = layoutParams.y
                    dragged = false
                    view.animate().scaleX(0.92f).scaleY(0.92f).setDuration(80).start()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragged && abs(dx) + abs(dy) > dp(6)) dragged = true
                    if (dragged) {
                        layoutParams.x = startX + dx.toInt()
                        layoutParams.y = startY + dy.toInt()
                        updatePosition(view, layoutParams)
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(80).start()
                    if (!dragged) {
                        Log.i(C2s.TAG, "悬浮球被点：去取剪贴板")
                        // 交给透明界面去读剪贴板（后台读不到内容）
                        ClipboardSpeakActivity.start(this)
                    } else {
                        C2s.setPosition(this, layoutParams.x, layoutParams.y)
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun updatePosition(view: View, layoutParams: WindowManager.LayoutParams) {
        try {
            windowManager?.updateViewLayout(view, layoutParams)
        } catch (_: Exception) {
            // 视图已经被移除等情况：忽略
        }
    }

    private fun removeButton() {
        val view = button ?: return
        button = null
        params = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
            // 已经不在窗口里了
        }
    }

    /** 系统悬浮窗的类型：Android 8 起必须用 APPLICATION_OVERLAY，否则直接被拒 */
    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics
    ).toInt()

    // ---------------- 剪贴板变化 ----------------

    /**
     * 监听剪贴板变化。
     *
     * Android 10+ 后台拿不到内容，但**变化本身**是能收到的，用它把球弹一下就够了：
     * 用户看到球跳了一下，就知道可以点它朗读。
     */
    private fun registerClipboardListener() {
        if (!C2s.autoShow(this)) return
        val manager = clipboard ?: return
        val listener = ClipboardManager.OnPrimaryClipChangedListener { pulse() }
        clipboardListener = listener
        try {
            manager.addPrimaryClipChangedListener(listener)
        } catch (_: Exception) {
            clipboardListener = null
        }
    }

    private fun unregisterClipboardListener() {
        val listener = clipboardListener ?: return
        clipboardListener = null
        try {
            clipboard?.removePrimaryClipChangedListener(listener)
        } catch (_: Exception) {
            // 忽略
        }
    }

    /** 弹一下悬浮球（复制之后给个可见反馈） */
    fun pulse() {
        val view = button ?: return
        view.post {
            view.animate().cancel()
            view.scaleX = 1f
            view.scaleY = 1f
            view.animate()
                .scaleX(1.25f)
                .scaleY(1.25f)
                .setDuration(140)
                .withEndAction {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(140).start()
                }
                .start()
        }
    }

    companion object {
        private const val CHANNEL_ID = "c2s_floating"
        private const val NOTIFICATION_ID = 0x2C25
        const val ACTION_PULSE = "com.example.tts_reader.C2S_PULSE"

        /** 当前实例（设置页据此判断是否在运行） */
        @Volatile
        var instance: FloatingSpeakService? = null
            private set

        fun isRunning(): Boolean = instance != null

        /** 启动悬浮球；已授权且开关打开时才真的启动 */
        fun start(context: Context) {
            if (!C2s.canDrawOverlay(context)) {
                C2s.requestOverlayPermission(context)
                return
            }
            val intent = Intent(context, FloatingSpeakService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 后台启动前台服务被拒（Android 12+ 的后台限制）：忽略，用户在前台时再开
                try {
                    context.startService(intent)
                } catch (_: Exception) {
                    // 真的起不来就算了，不要崩
                }
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, FloatingSpeakService::class.java))
            } catch (_: Exception) {
                // 忽略
            }
            instance = null
        }
    }
}
