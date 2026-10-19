package com.example.tts_reader

import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 耳机 / 平板的媒体键 → Flutter
 *
 * ## 为什么需要这一层
 *
 * 正常路径是 audio_service 的 MediaSession 接媒体键。但真机上（用户 2026-10-19，
 * 平板）出现「按耳机键没反应」—— 平板/部分 ROM 会把媒体键**当普通按键事件**
 * 直接派给前台 Activity，而不是走 MediaSession。
 *
 * 所以这里在 Activity 侧也接一道：`dispatchKeyEvent` 里认出媒体键就转给 Dart，
 * 由 Dart 决定是播放/暂停还是切句（不认识的状态 Dart 会忽略）。
 *
 * ## 为什么消费掉按键
 *
 * 不消费的话，同一个按键可能既走 MediaSession 又被这里收到 → 一次按下切两句。
 * Dart 侧另有一层 300ms 去重，双保险。
 */
object MediaKeyChannel {
    private const val CHANNEL = "tts_reader/media_keys"

    private var channel: MethodChannel? = null

    /** 应用 Context（注册媒体按钮接收器要用） */
    private var appContext: android.content.Context? = null

    /**
     * 当前是否「正在朗读」
     *
     * 只有 true 时我们才**消费**媒体键；空闲时不碰，让系统照旧走 MediaSession
     * （这样手机上原有的控制完全不受影响，只是朗读中多了一条兜底）。
     */
    private var active: Boolean = false

    /**
     * 试验：主动把自己注册成「媒体按钮接收器」
     *
     * `AudioManager.registerMediaButtonEventReceiver` 是 API 21 之前的老做法，
     * 新系统基本忽略它 —— 但**有些平板的固件仍然按这条路派发**。
     * 试一下没有副作用（失败就什么都不做）。
     */
    fun claimMediaButtons(context: android.content.Context) {
        try {
            val am = context.getSystemService(android.content.Context.AUDIO_SERVICE)
                as? android.media.AudioManager ?: return
            val component = android.content.ComponentName(
                context,
                TtsMediaButtonReceiver::class.java
            )
            @Suppress("DEPRECATION")
            am.registerMediaButtonEventReceiver(component)
            logKey(0, 0, false, note = "已注册媒体按钮接收器")
        } catch (e: Throwable) {
            logKey(0, 0, false, note = "注册媒体按钮接收器失败：$e")
        }
    }

    fun attach(messenger: BinaryMessenger, context: android.content.Context? = null) {
        appContext = context
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart 侧报告"是否正在朗读"
                "setActive" -> {
                    active = call.arguments == true
                    result.success(true)
                }
                // 试验：朗读开始时主动注册一次媒体按钮接收器
                "claimButtons" -> {
                    appContext?.let { claimMediaButtons(it) }
                    result.success(true)
                }
                // 朗读控制通知（自定义样式，不依赖媒体会话）
                "showNotice" -> {
                    val ctx = appContext
                    val args = call.arguments as? Map<*, *>
                    if (ctx != null && args != null) {
                        ReadingNotice.show(
                            ctx,
                            title = args["title"] as? String ?: "",
                            detail = args["detail"] as? String ?: "",
                            playing = args["playing"] == true,
                        )
                    }
                    result.success(true)
                }
                "hideNotice" -> {
                    appContext?.let { ReadingNotice.hide(it) }
                    result.success(true)
                }
                // 音量键长按切句的开关（Dart 侧跟设置同步）
                "setVolumeKeySkip" -> {
                    volumeKeySkip = call.arguments == true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    /**
     * 纯诊断：把按键事件记进日志（Dart 侧 CrashLog）
     *
     * 平板「按了没反应」时必须能分清两种可能：
     * ① 按键根本没到 Activity（系统路由给了别人）
     * ② 到了但我们没认出来 / 没接管
     * 打一行日志就能分辨。
     */
    /** 通知按钮的动作（ReadingNoticeReceiver 转进来）→ Dart，语义与按键完全一致 */
    fun dispatchAction(action: String) {
        channel?.invokeMethod("mediaKey", action)
    }

    fun logKey(
        keyCode: Int,
        action: Int,
        consumed: Boolean,
        note: String? = null,
    ) {
        val text = if (note != null) {
            note
        } else {
            "按键 key=$keyCode action=$action active=$active 已转发=$consumed"
        }
        channel?.invokeMethod("log", text)
    }

    /**
     * 广播路径收到的媒体键（[TtsMediaButtonReceiver] 转进来）
     *
     * 与 `dispatchKeyEvent` 那条路**共用同一套**动作翻译，所以 Dart 侧不用区分来源。
     * 广播只在我们「正在朗读」时才转，避免没在读也去抢别人的按键。
     */
    fun handleBroadcastKey(keyCode: Int, action: Int) {
        val isMedia = nameOf(keyCode) != null
        if (isMedia) {
            logKey(
                keyCode,
                action,
                active && action == KeyEvent.ACTION_DOWN,
                note = "广播按键 key=$keyCode action=$action active=$active",
            )
        }
        if (!active) return
        if (action != KeyEvent.ACTION_DOWN) return
        val name = nameOf(keyCode) ?: return
        channel?.invokeMethod("mediaKey", name)
    }

    /** 是否允许「音量键长按切句」（Dart 侧按设置同步过来） */
    private var volumeKeySkip: Boolean = false

    /**
     * 处理一个媒体键；返回 true 表示"这个键我们接了"（调用方应消费掉）
     *
     * ## 永远返回 false —— 一次也不消费
     *
     * 手机本来就能用 MediaSession 处理媒体键，我们只在**平板那种不走 MediaSession
     * 的 ROM** 上补一手。要保证"绝不影响手机"，就不能抢键：
     * 转发一份给 Dart，然后**原样放行**给系统。
     *
     * Dart 侧会等 150ms 再决定要不要动手 —— 这期间 MediaSession 已经处理过，
     * 它就会自己放弃（见 `MediaKeyState`）。所以不会出现"按一次切两句"。
     */
    fun handleKeyEvent(keyCode: Int, action: Int): Boolean {
        // 媒体类按键一律记一行（哪怕没接管）——平板排查全靠它
        val isMedia = nameOf(keyCode) != null
        if (isMedia) logKey(keyCode, action, active && action == KeyEvent.ACTION_DOWN)
        if (!active) return false
        if (action != KeyEvent.ACTION_DOWN) return false
        val name = nameOf(keyCode) ?: return false
        channel?.invokeMethod("mediaKey", name)
        return false
    }

    /**
     * 音量键**长按**切句（物理键替代方案）
     *
     * 为什么需要：有的平板固件根本不把耳机/蓝牙媒体键交给第三方应用
     * （真机 2026-10-19 诊断页连一条按键记录都没有）。音量键则一定会送到
     * 前台应用，所以拿它当替代。
     *
     * **只认长按**（`repeatCount > 0`）：短按照常调音量，不影响日常使用。
     * 返回 true 表示已消费（不要再调音量）。
     */
    fun handleVolumeKey(event: KeyEvent): Boolean {
        if (!volumeKeySkip || !active) return false
        if (event.repeatCount == 0) return false
        val name = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "next"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "previous"
            else -> return false
        }
        logKey(event.keyCode, event.action, true, note = "音量键长按 → $name")
        channel?.invokeMethod("mediaKey", name)
        return true
    }

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
