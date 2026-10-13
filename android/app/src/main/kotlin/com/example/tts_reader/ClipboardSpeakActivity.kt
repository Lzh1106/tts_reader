package com.example.tts_reader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager

/**
 * 取剪贴板用的透明界面（对应 T2S 里那个「读剪贴板时闪一下」的行为）。
 *
 * 为什么非要一个 Activity：Android 10 起，**只有获得输入焦点的应用**才能读到剪贴板内容，
 * 后台服务调用 `getPrimaryClip()` 一律返回 null。所以悬浮球 / 快捷磁贴被点之后，
 * 都由这里闪一下把内容读出来，再交给 Flutter 朗读，然后立刻 finish。
 *
 * 关键细节（设备测试抓到的）：**不能在 `onCreate` 里读**——那一刻窗口还没有输入焦点，
 * 拿到的同样是 null。要等 `onWindowFocusChanged(true)`。为了不出现「万一没拿到焦点就一直
 * 挂着一个看不见的界面」，还有一个超时兜底。
 *
 * 界面上什么都不画（透明 + 无动画 + 不进最近任务），用户基本无感。
 */
class ClipboardSpeakActivity : Activity() {

    private var handled = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(false)
        // 不接收触摸：透明界面不该拦住用户的任何操作
        window?.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        // 兜底：极少数情况下窗口拿不到焦点，也不能一直挂着
        handler.postDelayed({ takeClipboard("超时") }, FOCUS_TIMEOUT_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) takeClipboard("已获焦点")
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    /** 读剪贴板并交付朗读；只执行一次（焦点回调与超时兜底先到者生效） */
    private fun takeClipboard(reason: String) {
        if (handled) return
        handled = true
        handler.removeCallbacksAndMessages(null)

        val source = intent?.getStringExtra(EXTRA_SOURCE) ?: "c2s"
        val text = C2s.readClipboard(this)
        Log.i(C2s.TAG, "取词（$reason）：剪贴板 ${text.length} 字（source=$source）")
        if (text.isEmpty()) {
            C2s.toast(this, "剪贴板里没有文本")
        } else {
            C2s.speak(this, text, source)
        }
        finish()
    }

    override fun finish() {
        super.finish()
        // 透明界面不要有任何切换动画，否则屏幕上会闪一下
        overridePendingTransition(0, 0)
    }

    companion object {
        const val EXTRA_SOURCE = "source"

        /** 等焦点的时间上限 */
        private const val FOCUS_TIMEOUT_MS = 1200L

        /**
         * 启动取词界面。
         *
         * 这是「用户刚点过悬浮球 / 磁贴」的场景，属于系统允许的后台启动 Activity 例外
         * （logcat 里能看到 BAL_ALLOW_VISIBLE_WINDOW）；万一被拦（个别 ROM），
         * 退化成在服务里直接读，读不到会给提示而不是静默失败。
         */
        fun start(context: Context, source: String = "c2s") {
            val intent = Intent(context, ClipboardSpeakActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                putExtra(EXTRA_SOURCE, source)
            }
            try {
                context.startActivity(intent)
                Log.i(C2s.TAG, "已请求启动取词界面（source=$source）")
            } catch (e: Exception) {
                Log.w(C2s.TAG, "取词界面启动被拒：$e")
                C2s.speakClipboard(context, source)
            }
        }
    }
}
