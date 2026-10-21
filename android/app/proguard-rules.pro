# ============================================================================
# 桃花源阅读器 —— R8 / ProGuard 保留规则
#
# ## 为什么需要这个文件
#
# Flutter 的 Gradle 插件对 release 构建**默认开启 R8**（`minifyEnabled(true)`，
# 见 flutter.groovy 的 shouldShrinkResources 分支）。项目里原本没有这个文件，
# 于是 R8 用自己的判断裁剪「看起来没人用」的类。
#
# 已经踩过的坑（v1.22.49 手机耳机键彻底失效）：
#   · `TtsMediaButtonReceiver` 在 AndroidManifest.xml 里声明 → R8 保留；
#   · 它调用 `MediaKeyChannel.handleBroadcastKey(...)`；
#   · 但 `MediaKeyChannel` 是 Kotlin `object`，R8 认为没有外部入口 → **整个类被删**；
#   · 系统一广播按键，接收器就抛 NoClassDefFoundError，按键被静默丢弃。
#
# 症状极具欺骗性：**编译通过、安装正常、analyze 零问题**，只有真机按耳机键没反应。
# 用 dex 反查才能看出来（`MediaKeyChannel` 在 classes.dex 里根本不存在）。
#
# 结论：所有「由系统 / Manifest / 反射调用」的入口类，都必须在这里显式保留。
# ============================================================================

# ---------------------------------------------------------------------------
# 媒体键 / 耳机键：系统通过广播回调，R8 看不到这条引用
# ---------------------------------------------------------------------------
-keep class com.example.tts_reader.TtsMediaButtonReceiver { *; }
-keep class com.example.tts_reader.MediaKeyChannel { *; }

# ---------------------------------------------------------------------------
# 其余由系统按类名实例化的组件（Receiver / Service / TileService / Activity）
# 同样属于「Manifest 声明 → 系统反射创建」，一并兜住，
# 免得以后新增组件时再踩同一个坑。
# ---------------------------------------------------------------------------
-keep class com.example.tts_reader.C2sBootReceiver { *; }
-keep class com.example.tts_reader.FloatingSpeakService { *; }
-keep class com.example.tts_reader.ClipboardSpeakActivity { *; }
-keep class com.example.tts_reader.C2sSpeakTileService { *; }
-keep class com.example.tts_reader.C2sToggleTileService { *; }

# 各原生通道：Dart 侧按通道名调用，Kotlin 侧方法靠反射分发
-keep class com.example.tts_reader.C2sChannel { *; }
-keep class com.example.tts_reader.C2s { *; }
-keep class com.example.tts_reader.KeepAlive { *; }
-keep class com.example.tts_reader.FolderChannel { *; }
-keep class com.example.tts_reader.LameChannel { *; }
-keep class com.example.tts_reader.LameEncoder { *; }
-keep class com.example.tts_reader.IconChannel { *; }

# MainActivity：Flutter 引擎按类名加载
-keep class com.example.tts_reader.MainActivity { *; }

# ---------------------------------------------------------------------------
# Flutter 嵌入层
#
# ⚠️ 不要用 `-keep class io.flutter.** { *; }`：
# 它会把 deferred-components（Play Core 动态特性）相关类一起强制保留，
# 而那些类引用的 `com.google.android.play.core.*` 并不在本工程依赖里，
# R8 会直接报 "Missing class … Compilation failed to complete"。
# 只保留真正需要反射的部分即可。
# ---------------------------------------------------------------------------
-keep class io.flutter.embedding.android.FlutterActivity { *; }
-keep class io.flutter.embedding.android.FlutterFragmentActivity { *; }
-keep class io.flutter.plugin.common.MethodChannel { *; }
-keep class io.flutter.plugin.common.StandardMessageCodec { *; }
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.**

# 保留注解与泛型签名，避免反射/序列化踩坑
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
