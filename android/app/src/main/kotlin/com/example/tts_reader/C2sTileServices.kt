package com.example.tts_reader

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * 快捷设置磁贴：朗读剪贴板（对应 T2S 的 `SpeakClipboardTileService`）。
 *
 * 点一下就读当前剪贴板内容，不用先切到应用里；磁贴的亮/灭跟随「复制即朗读」总开关。
 */
@RequiresApi(Build.VERSION_CODES.N)
class C2sSpeakTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        launchClipboardReader()
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = if (C2s.isEnabled(this)) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "朗读剪贴板"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = "复制即朗读"
        }
        tile.updateTile()
    }

    /** 用透明界面取词（磁贴被点属于系统允许的后台启动场景） */
    private fun launchClipboardReader() {
        val intent = Intent(this, ClipboardSpeakActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            putExtra(ClipboardSpeakActivity.EXTRA_SOURCE, "c2s")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val pending = PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                startActivityAndCollapse(pending)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (_: Exception) {
            // 拉不起界面就退回直接读（读不到会给提示，不会静默失败）
            C2s.speakClipboard(this, "c2s")
        }
    }
}

/**
 * 快捷设置磁贴：开关悬浮朗读按钮（对应 T2S 的 `C2SSwitchTileService`）。
 *
 * 没授悬浮窗权限时点一下就跳到系统的授权页，省得用户自己找。
 */
@RequiresApi(Build.VERSION_CODES.N)
class C2sToggleTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (!C2s.canDrawOverlay(this)) {
            requestOverlayPermissionFromTile()
            return
        }
        val enabled = !C2s.isEnabled(this)
        C2s.setEnabled(this, enabled)
        if (enabled) {
            FloatingSpeakService.start(this)
            C2s.toast(this, "已开启悬浮朗读按钮")
        } else {
            FloatingSpeakService.stop(this)
            C2s.toast(this, "已关闭悬浮朗读按钮")
        }
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val on = C2s.isEnabled(this) && FloatingSpeakService.isRunning()
        tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = if (on) "悬浮朗读：开" else "悬浮朗读：关"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (C2s.canDrawOverlay(this)) "复制即朗读" else "需要悬浮窗权限"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            tile.stateDescription = if (on) "开启" else "关闭"
        }
        tile.updateTile()
    }

    private fun requestOverlayPermissionFromTile() {
        val intent = Intent(
            android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            android.net.Uri.parse("package:$packageName")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val pending = PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                startActivityAndCollapse(pending)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (_: Exception) {
            C2s.toast(this, "请到系统设置里授予「显示在其他应用上层」")
        }
    }
}
