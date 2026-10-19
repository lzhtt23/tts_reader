package com.example.tts_reader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStreamReader

/**
 * 继承 AudioServiceActivity：后台朗读时由 audio_service 托管前台服务与媒体通知。
 *
 * 同时充当 T2S 的「外部朗读入口」：
 * - 分享即朗读（ACTION_SEND + text/plain）
 * - 划词朗读（ACTION_PROCESS_TEXT）
 * - 打开文本朗读（ACTION_VIEW + content:// text/plain）
 *
 * 文本先落到 [pending]，Flutter 侧启动后调 `getPending` 取走；若 Flutter 已经在跑，
 * 直接 `invokeMethod("onText", …)` 推过去，界面立刻打开即读页开始朗读。
 */
class MainActivity : AudioServiceActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // 冷启动 / 恢复前台：把攒下的文本交给 Flutter
                "getPending" -> {
                    val payload = pending
                    pending = null
                    result.success(payload)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        // 复制即朗读（悬浮球 / 磁贴）的设置通道
        C2sChannel.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // 后台朗读保活（熄屏继续读）的电源通道
        KeepAlive.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // 「打开下载文件夹」通道（Android 没有标准 Intent，只能原生尽力而为）
        FolderChannel.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // MP3 导出用的 LAME 编码通道（tts_reader/lame；库缺失时返回 false，Dart 侧回退 WAV）
        LameChannel.attach(flutterEngine.dartExecutor.binaryMessenger)
        // 启动图标样式切换（tts_reader/icon：切 activity-alias，无需权限）
        IconChannel.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // 耳机 / 平板媒体键（tts_reader/media_keys）：
        // 平板有些 ROM 不走 MediaSession，直接把按键派给前台 Activity
        MediaKeyChannel.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // 引擎此刻才可用：把本次启动 intent 的文本补推一次
        deliverPending()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureIntent(intent)
    }

    /**
     * 媒体键兜底：平板 / 部分 ROM 会把耳机键当普通按键派给前台 Activity
     *
     * 先给 [MediaKeyChannel]，认出来就消费掉（避免同一按键又被 MediaSession 处理一次）。
     * 认不出（普通键）继续走系统默认。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // 音量键长按 → 切句（物理键替代方案，需在设置里打开）
        if (MediaKeyChannel.handleVolumeKey(event)) return true
        if (MediaKeyChannel.handleKeyEvent(event.keyCode, event.action)) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureIntent(intent)
    }

    /** 解析 intent 并把文本存好；拿不到文本时保持原状 */
    private fun captureIntent(intent: Intent?) {
        if (intent == null) return
        // 悬浮球 / 快捷磁贴把文本放在 extra 里带进来（冷启动路径）
        val extra = intent.getStringExtra(EXTRA_TEXT)
        if (!extra.isNullOrBlank()) {
            pending = payload(extra, intent.getStringExtra(EXTRA_SOURCE) ?: "c2s")
            deliverPending()
            return
        }
        // 深链：yuedu:// / legado:// 书源导入链接（网页上那个「一键导入」按钮）
        // 浏览器打不开自定义 scheme，只能交给系统；谁声明了这个 scheme 就交给谁。
        // 我们把整条链接原样推给 Dart，解析/确认/写库都在 Dart 侧做（与
        // 浏览器里点一键导入走同一条路），这里不做任何判断。
        val deepLink = intent.data
        if (intent.action == Intent.ACTION_VIEW && deepLink != null) {
            val scheme = deepLink.scheme?.lowercase()
            if (scheme == "yuedu" || scheme == "legado") {
                pending = payload(deepLink.toString(), "deeplink")
                deliverPending()
                return
            }
        }
        if (intent.action == Intent.ACTION_VIEW && intent.data != null) {
            // 读取 content:// 可能较慢（文件可能很大），放到后台线程
            val uri = intent.data!!
            val type = intent.type
            if (type != null && !type.startsWith("text/")) return
            Thread {
                val text = readText(uri)
                if (!text.isNullOrBlank()) {
                    Handler(Looper.getMainLooper()).post {
                        pending = payload(text, "view")
                        deliverPending()
                    }
                }
            }.start()
            return
        }
        val request = extract(intent) ?: return
        pending = request
        deliverPending()
    }

    private fun extract(intent: Intent): Map<String, Any?>? {
        val type = intent.type
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                if (text.isNullOrBlank()) null
                else if (type == null || type.startsWith("text/")) payload(text, "share")
                else null
            }
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                if (text.isNullOrBlank()) null else payload(text, "processText")
            }
            else -> null
        }
    }

    /** 读 content:// 的文本内容，最多读 [MAX_CHARS] 个字符（入口是附加能力，不能拖死进程） */
    private fun readText(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { stream ->
            InputStreamReader(stream, Charsets.UTF_8).use { reader ->
                val buffer = CharArray(8192)
                val builder = StringBuilder()
                while (builder.length < MAX_CHARS) {
                    val read = reader.read(buffer)
                    if (read <= 0) break
                    builder.append(buffer, 0, read)
                }
                builder.toString()
            }
        }
    } catch (_: Exception) {
        null
    } catch (_: OutOfMemoryError) {
        null
    }

    private fun payload(text: String, source: String): Map<String, Any?> =
        mapOf("text" to text, "source" to source)

    companion object {
        private const val CHANNEL = "tts_reader/intents"

        /** 入口文本的长度上限（与 Dart 侧 SpeakIntake.maxTextLength 对应） */
        private const val MAX_CHARS = 100000

        /** 悬浮球 / 快捷磁贴把文本塞进 intent 时用的 extra */
        const val EXTRA_TEXT = "tts_reader.text"
        const val EXTRA_SOURCE = "tts_reader.source"

        /** 待交付的文本；Activity 重建后依然有效 */
        @Volatile
        private var pending: Map<String, Any?>? = null

        /** 引擎可能比 Activity 活得久（audio_service 常驻），通道存成静态的 */
        @Volatile
        private var channel: MethodChannel? = null

        /** 从后台（悬浮球 / 磁贴 / 开机自启）交付文本：引擎在听就直接推过去 */
        @JvmStatic
        fun deliver(payload: Map<String, Any?>): Boolean {
            if (channel == null) return false
            pending = payload
            deliverPending()
            return true
        }

        /** 先攒下文本，等 Flutter 侧来取（冷启动路径） */
        @JvmStatic
        fun stash(payload: Map<String, Any?>) {
            pending = payload
        }

        /** 把攒下的文本推给 Flutter；成功后才清空，失败则留给下一次 getPending */
        @JvmStatic
        fun deliverPending() {
            val methodChannel = channel ?: return
            val request = pending ?: return
            methodChannel.invokeMethod("onText", request, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    pending = null
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    // Flutter 侧还没挂上处理器：留着，等它来 getPending
                }

                override fun notImplemented() = Unit
            })
        }
    }
}
