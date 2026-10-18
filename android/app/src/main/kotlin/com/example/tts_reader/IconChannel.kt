package com.example.tts_reader

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 启动图标样式切换。
 *
 * 原理：`AndroidManifest` 里为每种样式建一个 `activity-alias`（都指向 MainActivity，
 * 各自带 MAIN/LAUNCHER + 自己的图标）；主 Activity 本身不带 LAUNCHER。
 * 运行时只启用其中一个 alias，桌面就显示对应图标。
 *
 * 不需要任何权限 —— `setComponentEnabledSetting` 允许改自己应用的组件。
 *
 * ⚠️ 已知限制（不同 ROM 表现不一致）：
 * - 切换后桌面图标可能不立刻刷新（启动器缓存），需要等一会儿或重启启动器；
 * - 桌面已有的快捷方式指向旧 alias，切换后会消失/失效。
 * 所以设置里只提供"内置样式"，不支持自定义图片。
 */
object IconChannel {

    private const val CHANNEL = "tts_reader/icon"
    private const val PREFS = "tts_reader_icon"
    private const val KEY = "style"

    /** 样式 → alias 类名（与 AndroidManifest 一一对应） */
    private val ALIASES = linkedMapOf(
        "classic" to "com.example.tts_reader.LauncherClassic",
        "sickle" to "com.example.tts_reader.LauncherSickle",
        "books" to "com.example.tts_reader.LauncherBooks",
    )

    private const val DEFAULT = "classic"

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        // 启动时按偏好（默认 classic）把 alias 校准一次。
        // 只写清单里的 android:enabled 不够：组件启用状态是**系统侧持久化**的，
        // 从旧版本升级上来时系统沿用上次的状态，用户会看到「装完还是上一套图标」。
        runCatching { apply(app, load(app)) }
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(load(app))
                "set" -> {
                    val style = call.argument<String>("style")
                    if (style == null || !ALIASES.containsKey(style)) {
                        result.error("bad_style", "未知的图标样式: $style", null)
                    } else {
                        apply(app, style)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun load(context: Context): String {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null)
        return if (saved != null && ALIASES.containsKey(saved)) saved else DEFAULT
    }

    /**
     * 启用 [style] 对应的 alias，停用其它。
     *
     * 顺序很重要：**先启用新的，再停用旧的** —— 反过来的话中间会有一瞬间
     * 一个入口都没有，某些启动器会把图标直接移除。
     */
    private fun apply(context: Context, style: String) {
        val pm = context.packageManager
        val target = ComponentName(context.packageName, ALIASES.getValue(style))
        pm.setComponentEnabledSetting(
            target,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        for ((name, cls) in ALIASES) {
            if (name == style) continue
            pm.setComponentEnabledSetting(
                ComponentName(context.packageName, cls),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, style).apply()
    }
}
