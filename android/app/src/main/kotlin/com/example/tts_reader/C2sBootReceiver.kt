package com.example.tts_reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机自启（对应 T2S 的 `RECEIVE_BOOT_COMPLETED` + 开机拉起 C2S 服务）。
 *
 * 只在用户主动开过「复制即朗读」且已授权悬浮窗时才拉起悬浮球；
 * Android 12+ 对后台启动前台服务有限制，起不来就安静放弃（回到前台时设置页会重新拉起）。
 */
class C2sBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        if (!C2s.isEnabled(context)) return
        if (!C2s.canDrawOverlay(context)) return
        FloatingSpeakService.start(context)
    }
}
