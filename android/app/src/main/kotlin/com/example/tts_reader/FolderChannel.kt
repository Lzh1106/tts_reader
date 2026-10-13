package com.example.tts_reader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 「打开下载文件夹」的平台通道（`tts_reader/folder`）。
 *
 * ## 为什么必须走原生
 *
 * Android **没有**「打开某个目录」的标准 Intent：
 * - `ACTION_VIEW` + `resource/folder` 只有**部分**第三方文件管理器认
 *   （MIUI / ColorOS 的文件管理、Solid Explorer、FX 认；Google 的 Files 不认）；
 * - `file://` URI 在 Android 7+ 直接抛 `FileUriExposedException`；
 * - SAF 的 `ACTION_OPEN_DOCUMENT_TREE` 是**选**目录，不是**看**目录。
 *
 * ## 策略：能开就开，开不了如实回报
 *
 * 三条路依次试，**任何一条成功就返回 true**：
 * 1. `ACTION_VIEW` + `DocumentsContract` 目录 URI（一部分文件管理器认这个）；
 * 2. `ACTION_VIEW` + `FileProvider` 授权的 `content://` URI + MIME 为 resource斜杠folder；
 * 3. `ACTION_VIEW` + `content://`，MIME 用通配（星号斜杠星号）。
 *
 * 全失败返回 false —— Dart 侧据此退回「显示路径 + 文件清单」的面板，
 * 并在文案里告诉用户"这台机器没有能打开的文件夹管理器"。
 *
 * ⚠️ Kotlin 的块注释**不能嵌套**，且注释里**绝对不能出现**"星号 + 斜杠"这组字符
 * （本文件踩过两次：一是 MIME 通配写法，二是给字加粗时的收尾）。
 * 一旦出现，注释就会被提前结束，编译报 "Expecting a top level declaration"。
 * 所以上面第 3 条只能写成文字描述。
 */
object FolderChannel {

    const val NAME = "tts_reader/folder"

    /**
     * logcat 标签（v1.21.43 追加）。
     *
     * ## 为什么原生侧必须有日志
     *
     * 用户报「点 📂 闪退」，而 **Dart 的 `crash.log` 完全看不到** ——
     * 原生层崩溃（未捕获异常 / SIGSEGV）**根本不经过 Dart**，进程直接没。
     * 这个盲区害我误判过一次（把"crash.log 没记录"当成"所以是 Dart 层"）。
     *
     * 加日志后可以用：
     * ```
     * adb logcat -s TTS_FOLDER
     * ```
     * 看 📂 到底走到哪一步 —— 崩在哪一步一目了然。
     */
    private const val TAG = "TTS_FOLDER"

    /** 用 flutter_downloader 自带的 FileProvider 授权（manifest 里已声明） */
    private const val PROVIDER_SUFFIX = ".flutter_downloader.provider"

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    result.success(open(activity, path))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 试着打开 [path] 这个目录；真打开了返回 true */
    private fun open(activity: Activity, path: String): Boolean {
        val dir = File(path)
        Log.i(TAG, "① 进入 open path=$path exists=${dir.exists()} " +
                "canRead=${dir.canRead()} isDir=${dir.isDirectory}")
        if (!dir.exists()) {
            Log.i(TAG, "① 目录不存在 → 直接返回 false（不发起任何 Intent）")
            return false
        }

        // ① DocumentsContract 目录 URI
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val uri = externalStorageDocUri(path)
            Log.i(TAG, "② DocumentsContract uri=$uri")
            if (uri != null && tryView(activity, uri, DocumentsContract.Document.MIME_TYPE_DIR)) {
                return true
            }
        }

        // ② FileProvider 授权的 content:// + resource/folder
        val pUri = providerUri(activity, dir)
        Log.i(TAG, "③ FileProvider uri=$pUri")
        if (pUri != null) {
            if (tryView(activity, pUri, "resource/folder")) return true
            // ③ 同一个 URI，换个 MIME 再试
            if (tryView(activity, pUri, "*/*")) return true
        }

        Log.i(TAG, "④ 三条路全失败 → 返回 false（Dart 侧会退回面板）")
        return false
    }

    /**
     * 把 `/storage/emulated/0/Download` 这类路径转成
     * `content://com.android.externalstorage.documents/document/primary%3ADownload`
     *
     * ⚠️ 必须覆盖 **`Android/data/<包名>/...`** 这种子路径（v1.21.41 追加）：
     * 设置页的「存到外部存储」把下载目录设到
     * `/storage/emulated/0/Android/data/<包名>/files/downloads` ——
     * 用户点 📂 时也要能跳到那儿，而不是永远跳系统「下载」。
     *
     * 注意 `externalStorageDocUri` 这类 URI 由系统 ExternalStorageProvider 提供，
     * `Android/data` 属于它的管辖范围（个别 ROM 会在 DocumentsUI 里隐藏该目录，
     * 那种情况下面还有 FileProvider 那条路兜着）。
     */
    private fun externalStorageDocUri(path: String): Uri? {
        val prefix = "/storage/emulated/0/"
        if (!path.startsWith(prefix)) return null
        val relative = path.removePrefix(prefix).trimEnd('/')
        if (relative.isEmpty()) return null
        val docId = "primary:$relative"
        return DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", docId)
    }

    /** 用 flutter_downloader 的 FileProvider 把文件路径换成 content:// */
    private fun providerUri(activity: Activity, dir: File): Uri? = try {
        val authority = activity.packageName + PROVIDER_SUFFIX
        // ⚠️ 用**反射**调 `FileProvider.getUriForFile`，不写 `androidx.core` 的 import：
        // 那个类只是**传递依赖**（插件带进来的），本工程 `build.gradle` 里没有
        // `dependencies` 段、也没直接声明 androidx.core —— 直接 import 会让编译
        // 依赖一个没写明的包（换个插件版本就可能编不过）。
        // 运行时它一定在（flutter_downloader 的 provider 就是它的子类）。
        val clazz = Class.forName("androidx.core.content.FileProvider")
        val method = clazz.getMethod(
            "getUriForFile",
            android.content.Context::class.java,
            String::class.java,
            File::class.java,
        )
        method.invoke(null, activity, authority, dir) as? Uri
    } catch (_: Exception) {
        // provider 没声明 / 路径不在白名单 / 反射失败 → 这条路走不通
        null
    }

    /** 发起 ACTION_VIEW；没有应用能处理就返回 false（不抛给上层） */
    private fun tryView(activity: Activity, uri: Uri, mime: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            activity.startActivity(intent)
            Log.i(TAG, "   ✔ 已发出 Intent mime=$mime")
            true
        } catch (e: ActivityNotFoundException) {
            Log.i(TAG, "   ✘ 没有应用能处理 mime=$mime（${e.javaClass.simpleName}）")
            false
        } catch (e: Exception) {
            // SecurityException 等：同样当作"这条路不行"，交给下一条
            // ⚠️ 这里必须把**异常类名**打出来：ROM 差异导致的失败原因各不相同，
            // 只写"失败了"等于没写。
            Log.w(TAG, "   ✘ Intent 失败 mime=$mime ${e.javaClass.name}: ${e.message}")
            false
        }
    }
}
