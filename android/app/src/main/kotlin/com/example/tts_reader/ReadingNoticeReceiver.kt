package com.example.tts_reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 朗读通知按钮 → Dart
 *
 * 走**广播**而不是媒体会话：通知里的每个按钮是 `PendingIntent` 直投这个接收器，
 * 完全绕开「媒体会话 / 耳机键」那套路由（真机上那套不稳定）。
 *
 * 动作名与 `MediaKeyChannel` 共用同一套（`play_pause` / `next` / `previous` /
 * `stop`），Dart 侧已有对应处理，这里只负责转发。
 */
class ReadingNoticeReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_NOTICE = "tts_reader.notice.action"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null || intent.action != ACTION_NOTICE) return
        val action = intent.getStringExtra(ReadingNotice.EXTRA_ACTION) ?: return
        android.util.Log.i("ReadingNotice", "button=$action")
        MediaKeyChannel.dispatchAction(action)
    }
}
