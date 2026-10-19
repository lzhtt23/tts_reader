package com.example.tts_reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent

/**
 * `ACTION_MEDIA_BUTTON` 广播接收器（实验性兜底）
 *
 * ## 为什么还要自己写一个
 *
 * 平板实测（用户 2026-10-19）：通知栏按钮能用、诊断页也有记录，但**耳机键一条记录都没有**
 * —— 说明系统没把按键派给我们的 MediaSession。audio_service 自带的
 * `MediaButtonReceiver` 只负责把按键转给它的会话，会话没被选中时同样收不到。
 *
 * Android 在「没有会话愿意处理」时会把按键**广播**出来（老机制，
 * `MediaSessionCompat` 之前的做法）。多注册一个高优先级接收器就有机会接住 ——
 * 接住就把动作转给 Dart，和原生 `dispatchKeyEvent` 走同一条路。
 *
 * 收不到也不会有副作用：只是一个没人调的接收器。
 */
class TtsMediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return
        val event: KeyEvent? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        if (event == null) return
        MediaKeyChannel.handleBroadcastKey(event.keyCode, event.action)
    }
}
