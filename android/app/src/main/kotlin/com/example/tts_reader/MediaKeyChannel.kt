package com.example.tts_reader

import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 媒体键 → Flutter 的转发通道
 *
 * ## 职责边界（重要）
 *
 * 这一层**只做一件事**：把 Android 的 keyCode 翻译成动作名，转发给 Dart。
 *
 * 它**不判断**"现在是否在朗读"、"要不要接管"。这个判断必须放在 Dart 侧，
 * 原因见 [TtsMediaButtonReceiver] 的注释：原生侧持有的 `active` 标记会与
 * 真实状态脱节，而脱节的表现就是**按键被静默丢弃**。
 *
 * ## 为什么用单向通道
 *
 * 不需要 Dart 回话。Dart 收到 `mediaKey` 后自己决定播/停/切句。
 * 通道只在 Dart 侧监听，因此这里不需要 setMethodCallHandler。
 */
object MediaKeyChannel {

    private const val CHANNEL = "tts_reader/media_keys"

    private const val TAG = "TtsMediaKey"

    private var channel: MethodChannel? = null

    /** 挂上通道（MainActivity.configureFlutterEngine 里调用一次） */
    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        Log.i(TAG, "媒体键通道已挂载")
    }

    /**
     * 广播路径收到按键（[TtsMediaButtonReceiver] 调用）
     *
     * **无条件转发**，不判断状态 —— 见类注释。
     *
     * ⚠️ **只保留这一条路**。v1.22.52 曾新增一条「Activity 直派」的并行入口，
     * 结果手机坏掉：同一次按键被广播与 Activity 各收一次 → 执行两遍
     * （暂停又立刻播放 = 看起来完全没反应）。见 `MainActivity` 里那段说明。
     */
    fun onBroadcastKey(keyCode: Int) {
        forward(keyCode)
    }

    /** 转发逻辑 */
    private fun forward(keyCode: Int) {
        val action = nameOf(keyCode) ?: return
        val ch = channel
        if (ch == null) {
            // 通道为 null：Activity 没起来 / Flutter 引擎未就绪
            Log.i(TAG, "按键 $action 但通道为 null")
            return
        }
        Log.i(TAG, "按键 → 转发 $action")
        ch.invokeMethod("mediaKey", action)
    }

    /**
     * keyCode → 动作名
     *
     * 注意 ColorOS（一加 / OPPO）把耳机键统一发成 `KEYCODE_MEDIA_PLAY`，
     * **不发**标准的 `MEDIA_PLAY_PAUSE`，所以两个都映射到 `play_pause`，
     * 由 Dart 侧按当前状态决定是"播"还是"停"。
     */
    private fun nameOf(keyCode: Int): String? = when (keyCode) {
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_HEADSETHOOK,
        KeyEvent.KEYCODE_MEDIA_PLAY,
        -> "play_pause"

        KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
        KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
        KeyEvent.KEYCODE_MEDIA_STOP -> "stop"
        else -> null
    }
}
