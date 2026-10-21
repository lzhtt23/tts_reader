import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';

import '../services/crash_log.dart';
import '../services/media_key_state.dart';
import '../features/pdf_reading/pdf_read_session.dart';
import 'audio_session_source.dart';
import 'media_interruption.dart';
import 'tts_manager.dart';

/// 平板等「暂停后耳机键失效」的设备上为 true
///
/// 让通知保持 ongoing，且暂停时也不退出前台服务 —— 这样系统才会一直把我们
/// 当作媒体按键的接收方（`dumpsys media_session` 里 `Media button session`
/// 不再变成 null）。手机实测旧值（false/false）正常，所以**按设备类型切换**，
/// 不改手机的既有行为。
bool get _keepAliveInBackground => _isTabletDevice();

bool _isTabletDevice() {
  try {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final double shortest =
        view.physicalSize.shortestSide / view.devicePixelRatio;
    return shortest >= 600;
  } catch (_) {
    return false;
  }
}

/// 全局持有，避免被回收
TtsAudioHandler? audioHandler;

/// 把 TtsManager 接到系统媒体通知上：
/// 前台服务保证退到后台仍能继续朗读，通知栏提供播放 / 暂停 / 上下章 / 停止与进度拖动。
///
/// **耳机 / 蓝牙按键也走这里**：Android 把耳机按键统一映射成媒体键
/// （播放/暂停、上一首、下一首），系统通过 MediaSession 送到下面这几个方法 ——
/// `play` / `pause` / `skipToNext` / `skipToPrevious`。
/// 「上一首 / 下一首」的动作由设置决定（按句 or 按章）。
class TtsAudioHandler extends BaseAudioHandler {
  TtsAudioHandler(this._manager) {
    // 默认来源是 TtsManager：原有行为完全不变（有设备用例守着）
    _source = _manager;
    _manager.addListener(_sync);
    // 系统打断（来电 / 别的播放器抢焦点）：暂停并记住，结束后自动继续
    MediaInterruptionController.instance.pauseForInterruption = () async {
      final source = _source;
      // ★诊断（v1.21.48）：记下"打断时到底在不在读"，否则事后无法区分
      // 「本来就没在播（与打断无关）」与「在播、被我们停了」。
      CrashLog.mark('打断暂停[进入] source=${source.sourceId} '
          'hasSession=${source.hasSession} playing=${source.playing} '
          'paused=${source.paused}');
      if (!source.hasSession || !source.playing) {
        CrashLog.mark('打断暂停[跳过] 没有会话或没在播 → 不暂停');
        return;
      }
      await source.pause();
      CrashLog.mark('打断暂停[完成] playing=${source.playing} '
          'paused=${source.paused}');
    };
    MediaInterruptionController.instance.resumeAfterInterruption = () async {
      final source = _source;
      CrashLog.mark('打断接回[进入] source=${source.sourceId} '
          'hasSession=${source.hasSession} playing=${source.playing} '
          'paused=${source.paused}');
      if (!source.hasSession) {
        CrashLog.mark('打断接回[跳过] 没有会话（!）');
        return;
      }
      source.playFromCursor();
      // ★这一行是取证关键：调完接回之后**到底有没有真的在播**。
      // `playing=false` = "接了但没接上" → 问题在引擎 / 会话，不在打断链。
      CrashLog.mark('打断接回[完成] playing=${source.playing} '
          'paused=${source.paused}（playing=false 就是没接上）');
    };
    // ★v1.21.45 改动 1：**长打断结束**只重推一次播放状态，不碰播放。
    //
    // 真机现象：被别的应用抢走音频焦点（长打断）之后，**耳机键失效**，
    // 而应用内按钮与通知栏按钮都正常 → 怀疑系统在此期间把我们当成"非活跃媒体"。
    // 长打断结束时重推一次 `playbackState`，让系统重新把我们标成活跃媒体，
    // 媒体键的路由就会回来。
    //
    // ⚠️ 这是**第一轮尝试**，根因未定性：真机验收要看日志里有没有
    // `媒体控制[pushState]`。若一条都没有 / 按键仍无效，说明重推状态不足以改路由，
    // 下一步才动焦点策略（见交接文档「耳机修复无效时的下一步」）。
    MediaInterruptionController.instance.notifyAfterInterruptionEnded = () async {
      _pushState();
    };
  }

  static const String _notificationChannelId = 'com.example.tts_reader.audio';

  /// 通知栏回退标题（未绑定文档时显示）
  static const String appName = '桃花源阅读器';

  /// 会话结束、但卡片保留时显示的标题（§4.104）
  ///
  final TtsManager _manager;

  /// 当前正在驱动通知栏的会话来源
  ///
  /// 可能是 [TtsManager]（TXT / EPUB）或 `PdfReadSession`（PDF）。
  /// 切换只能走 [activate] —— 千万别在 `TtsManager.stop()` 里调（HANDOFF §4.65）。
  late AudioSessionSource _source;

  /// 当前来源的 id（判「有没有换来源」用）
  String _sourceId = '';

  /// 进度用一个「每单元一秒」的伪时间轴表示，通知栏据此显示进度条并可拖动
  ///
  /// 「单元」对 TXT 是**句**、对 PDF 是**页** —— 只是刻度约定，不要求同义。
  static const int _unitMillis = 1000;

  /// 是否已经推过一次通知（用户按下播放前不打扰通知栏）
  bool _started = false;

  /// 切到某个会话来源
  ///
  /// **幂等**：同 id 重复调用直接返回，否则每读一句都会重建通知、进度条乱闪。
  ///
  /// 调用点只有三处：`TtsManager._restart()` / `TtsManager.speakLines()` /
  /// `PdfReadSession.startAt()`。**不要**放进 `TtsManager.stop()`。
  ///
  /// ⚠️ **不要**为了"让 `_source` 跟到最新实例"把赋值挪到短路之前（v1.21.43 踩过）：
  /// 那样会与「PDF 借声期间起 EPUB」那套状态机打架，
  /// `test/borrow_audio_session_test.dart` 4 条 + `cross_session_source_test.dart`
  /// 1 条会一起变红（`hasSession` / 通知栏指向错来源）。
  /// 真机那条「PDF 朗读时媒体无法打断」的根因**不在本方法** ——
  /// 是 PDF 借声路径没申请音频焦点，修在 `TtsManager._speakLinesInternal`。
  void activate(AudioSessionSource source) {
    if (source.sourceId == _sourceId) {
      // 同一来源：只把引用换掉（可能换了实例，但语义相同），不重建通知
      _source = source;
      return;
    }
    // 先让旧来源停手：否则它还会往通知栏推自己的状态（两本书抢一条通知）
    _source.onStop();
    _source = source;
    _sourceId = source.sourceId;
    // 新来源一上来就推一次状态，通知栏立刻显示正确内容。
    //
    // ⚠️ 这里必须调 `_pushState()` 而**不是** `_sync()`：`_sync` 是挂在
    // TtsManager listener 上的入口，开头有一道「当前来源不是 TtsManager 就
    // 直接返回」的闸门 —— 换到 PDF 来源时调它等于什么都没推，
    // 通知栏会一直停在上一本书（实测踩到，表现为通知栏显示 TXT 的书名）。
    _diag('activate（换源）${source.sourceId}');
    _started = true;
    _pushState();
  }

  /// 释放某个来源：如果是当前来源就清掉（换书 / 通知栏关闭）
  void release(AudioSessionSource source) {
    if (source.sourceId != _sourceId) return;
    _sourceId = '';
    _started = false;
  }

  /// 初始化后台音频服务（桌面 / 测试环境不支持时返回 null）
  static Future<TtsAudioHandler?> init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      final handler = await AudioService.init(
        builder: () => TtsAudioHandler(TtsManager.instance),
        // not const: the two background-keepalive flags are resolved at runtime
        config: AudioServiceConfig(
          androidNotificationChannelId: _notificationChannelId,
          androidNotificationChannelName: '朗读控制',
          androidNotificationChannelDescription: '显示朗读进度并控制播放',
          // ⚠️ 这两个必须**成对**为 false：audio_service 里有断言
          // `assert(!androidNotificationOngoing || androidStopForegroundOnPause)`。
          //
          // 语义没变差：前台服务活着时，系统本来就会把通知强制成 ongoing，
          // 所以「暂停时划不掉」这条依旧成立（= 用户选的 B）；
          // 而 active 的 FGS 正好保证熄屏/后台时媒体键还有人处理。
          androidNotificationOngoing: _keepAliveInBackground,
          // v1.21.14 任务②（用户拍板选 B）：**暂停也不退出前台服务**。
          //
          // 原值 true 的代价（实测）：暂停即退出前台服务 → 熄屏 + 后台时，
          // Android 12+ 限制后台重启前台服务、进程也可能被冻结 →
          // 耳机/通知栏的「播放」键**根本没人处理**：
          //   亮屏：79 暂停 ✓ / 126 播放 ✓ / 85 ✓
          //   熄屏：79 暂停 ✓，126/85 **完全无反应**（连一次状态都没推）
          // 换成 false 后，熄屏 / 后台也能用耳机恢复播放。
          androidStopForegroundOnPause: _keepAliveInBackground,
          androidNotificationIcon: 'drawable/ic_stat_speech',
        ),
      );
      audioHandler = handler;
      // 应用启动就把音频属性 / 打断监听装好，并按设置择一配置
      await MediaInterruptionController.instance.applySettings();
      return handler;
    } catch (_) {
      return null;
    }
  }

  /// 把当前来源的状态推给通知栏
  ///
  /// ⚠️ 这个方法同时挂在 `TtsManager` 的 listener 上，但**只在该来源就是当前
  /// 来源时**才推 —— 否则 PDF 会话在放的时候，TtsManager 的任何一次 notify
  /// 都会把通知栏改回 TXT 的内容（两本书抢一条通知）。
  void _sync() {
    // v1.21.25：PDF 借 TtsManager 发声期间 `hasSession` 恒为 false，
    // 此时推 idle 会让 audio_service 按默认行为收掉卡片（而声音还在播）。
    if (_manager.isBorrowedForOther) return;
    // TtsManager 的 listener 触发的同步：当前来源不是它就忽略
    if (!identical(_source, _manager)) return;
    _pushState();
  }

  /// 按当前来源重建通知栏内容（与触发方式无关）
  void _pushState() {
    final source = _source;
    final hasSession = source.hasSession;
    // 用户按下播放前不打扰通知栏
    if (!_started) {
      if (!hasSession) return;
      _started = true;
    }
    if (!hasSession) {
      // 会话没了 = 停止播放 → 推 `idle`，交给 audio_service 的**默认行为**收掉卡片。
      //
      // 见 `audio_service-0.18.17/lib/audio_service.dart` 的 playbackState 监听：
      // ```dart
      // if (playbackState.processingState == AudioProcessingState.idle &&
      //     previousState?.processingState != AudioProcessingState.idle) {
      //   await AudioService._stop();      // → stopService() ⇒ 卡片消失
      // }
      // ```
      // 这正是本轮需求的语义：**有朗读会话 → 卡片显示当前正在朗读的文档；
      // 会话结束（stop / clear）→ 卡片消失**。
      // v1.21.6 / §4.104 的「卡片保留 + 未在播放」中间态已撤销。
      _diag('pushState→idle（卡片消失）');
      // 没会话了 → 自定义朗读通知也收掉
      playbackState.add(PlaybackState(
        controls: const <MediaControl>[],
        systemActions: <MediaAction>{},
        processingState: AudioProcessingState.idle,
        playing: false,
      ));
      return;
    }

    final total = source.progressTotal;
    final index = source.progressIndex;
    final playing = source.playing;
    // ★v1.21.52：**正在播就说明"那次打断已经翻篇了"**，清掉"已让位"标志。
    //
    // 为什么放在这里：`_pushState()` 是**所有来源**（TtsManager 与 PDF 会话）
    // 唯一的公共出口 —— 应用内点播放、通知栏点播放、PDF 恢复，最终都会走到这。
    // 只清 `TtsManager._restart` 那一处会漏掉 PDF 会话那条路。
    //
    // 不清的后果（真机日志 2026-10-15 00:25 实证）：用户看完视频手动恢复后，
    // 标志留成 true → **下一个视频会被当成"已经让位过"而不再让位**。
    if (playing) MediaInterruptionController.instance.notifyUserResumed();
    // v1.21.43 埋点：**非 idle 的推送**以前没有日志，导致真机手测 ② 只能猜
    // （「应用内恢复后通知栏图标没变」到底是我们没推、还是推了 ROM 没重绘）。
    // 这条每次推送只打一行，低频（每句一次），加进来能把责任分清楚。
    CrashLog.mark('媒体控制[pushState] source=${source.sourceId} '
        'playing=$playing paused=${source.paused} '
        'controls=${playing ? "pause" : "play"} index=$index/$total');
    final title =
        source.documentTitle.isEmpty ? appName : source.documentTitle;
    final subtitle = source.positionLabel;

    mediaItem.add(
      MediaItem(
        id: 'tts_reader',
        title: title,
        // v1.21.17 第 5 件：副标题**跟随状态**。
        // 原来不管播没播都写「点击播放开始朗读」——真机截图里正在朗读时也是这句，
        // 看起来像"没在播"。（`positionLabel` 为空的场景：纯文本 / 外部文本入口。）
        artist: subtitle.isNotEmpty
            ? subtitle
            : (playing ? '正在朗读' : '点击播放开始朗读'),
        duration: Duration(milliseconds: total * _unitMillis),
      ),
    );

    playbackState.add(
      PlaybackState(
        // ⚠️ 图标为何用显式 `playing ? pause : play`（而不是 `playPause`）：
        //
        // 任务书建议改用 `MediaControl.playPause`（单一 ACTION_PLAY_PAUSE）试修 ColorOS 的
        // 图标反向问题，但**本工程锁的 audio_service 0.18.17 没有这个常量** ——
        // 只有 `MediaControl.stop/pause/play/rewind/skipToNext/skipToPrevious/fastForward`，
        // 另有一个枚举值 `MediaAction.playPause`。要手搓就得给 `MediaControl` 指定
        // `androidIcon`（形如 `drawable/…`）与资源名，而本应用**没有打包那个 drawable**；
        // 资源不存在时有把通知栏构建搞崩的风险，收益只是"可能修好图标"，不值当。
        //
        // 因此保持显式写法：标准 Android 会据此渲染 ⏸ / ▶ 并发出
        // KEYCODE_MEDIA_PAUSE / KEYCODE_MEDIA_PLAY。ColorOS 忽略 `playing` 字段、
        // 按自己的规则恒画 ▶（真机实测：媒体键恒发 KEYCODE_MEDIA_PLAY），
        // 这是 **ROM 层行为，app 侧改不了**。
        //
        // 点击行为仍然正确：媒体键事件分派做了 ROM 兼容
        //（`play()` 收到 playing=true 时当 pause 用，见 v1.21.15）。
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        // 能不能拖由来源说了算：PDF 会话不给 seek，避免「拖了没反应」
        systemActions: source.canSeek
            ? const <MediaAction>{MediaAction.seek}
            : const <MediaAction>{},
        androidCompactActionIndices: const <int>[0, 1, 3],
        processingState: AudioProcessingState.ready,
        // ★v1.22.30（用户选的方案 C）：只有**被其它媒体打断**造成的暂停，
        // 才继续以 PLAYING 上报 —— 这样系统仍把我们当「媒体按钮会话」，
        // 耳机键在打断后立刻可用（否则实测 `Media button session is null`）。
        // 用户**自己按暂停**时照旧上报 PAUSED，通知栏状态保持准确。
        playing: playing,
        updatePosition: Duration(milliseconds: index * _unitMillis),
        speed: source.rate,
        queueIndex: index,
      ),
    );
    // 记下这次推出去的播放态：`syncAfterUserCommand()` 靠它判断"变了没有"
    _lastPushedPlayState = (playing, source.paused);
  }

  /// 当前来源自己推状态时用（PDF 会话没有挂在 TtsManager 的 listener 上）
  void notifyFromSource() => _pushState();

  /// 媒体控制埋点（v1.21.15）：记录「哪个入口被触发、当时来源是什么状态」
  ///
  /// 用途：真机上排查「耳机键没反应 / 通知栏不同步」这类**只能复现、没法断点**的问题。
  /// 打点只在**低频入口**（媒体键、通知栏命令、换源、卡片消失）——
  /// **不进** `_pushState()` 的常规分支，那个每读一句都会跑，打点会把日志淹掉。
  ///
  /// 取日志：设置页「诊断日志」→ 复制；或
  /// `adb shell run-as com.example.tts_reader cat app_flutter/crash.log`。
  void _diag(String action) {
    final AudioSessionSource source = _source;
    CrashLog.mark('媒体控制[$action] source=${source.sourceId} '
        'hasSession=${source.hasSession} playing=${source.playing} '
        'paused=${source.paused}');
  }

  /// 当前是否处于播放中（供界面查询通知栏状态）
  ///
  /// ⚠️ v1.21.14 任务②：**直读来源**，不再自己存一份 `_lastPlaying`。
  /// 存副本的老写法有过实测事故（旧 `library_bar_notification_test` 记过：
  /// 会话已经结束、`handler.isPlaying` 仍为 true）——播放状态必须只有一个真相源。
  bool get isPlaying => _source.playing;

  /// 上一次**推给通知栏**的播放态：`(playing, paused)`
  ///
  /// ⚠️ 这是**推送去重的快照**，不是"播放状态的真相源"（真相源永远只有 [_source]）。
  /// 用途见 [syncAfterUserCommand]：媒体键改完状态后，只有**真的变了**才推一次，
  /// 避免跟 `_sync()` / 来源自己的 `_notifyAudio()` 重复推。
  (bool, bool)? _lastPushedPlayState;

  /// 用户级命令（耳机 / 通知栏按钮）改完状态后，**确保通知栏跟上了**
  ///
  /// ## 为什么需要它（v1.21.39 修「耳机暂停后通知栏图标不同步」）
  ///
  /// 两个来源推通知栏的路径**不一样**：
  /// - `TtsManager`（TXT / EPUB）挂在它的 listener 上 → `_sync()`；
  /// - `PdfReadSession` **不挂 listener**，靠自己的 `_notifyAudio()` 推。
  ///
  /// 而 `_sync()` 开头有一道闸门：**当前来源不是 `TtsManager` 就直接返回**
  /// （那是为了防"两本书抢一条通知"）。于是「来源不是 TtsManager 时状态变了」这件事
  /// 只能靠来源自己推 —— 一旦某条路径漏推，通知栏就停在旧状态（图标不同步）。
  ///
  /// 这里在**媒体键出口**补一道兜底：状态真变了就推一次。
  /// 判据用 [_lastPushedPlayState] 而不是无条件推 —— 每读一句都会走 `_pushState()`，
  /// 无条件推会让系统频繁重建通知卡片。
  void syncAfterUserCommand() {
    final state = (_source.playing, _source.paused);
    if (_lastPushedPlayState == state) return;
    _pushState();
  }

  /// 当前通知栏的来源（测试用）
  AudioSessionSource get activeSource => _source;

  /// 耳机 / 通知栏「播放」：先让声音响起来，再去申请音频焦点
  ///
  /// v1.21.14 任务②：**顺序反了会出事**。原来先 `await requestFocus()` 再
  /// `playFromCursor()` —— 焦点申请是一次平台往返，它慢一拍或卡住时，
  /// 用户看到的就是「按了播放键没反应」（而 `skipToNext/skipToPrevious`
  /// 那几条都是零 await 直接调，所以从来没这个问题）。
  /// 焦点只是"礼貌"（让别人 duck），不该挡在出声前面；
  /// `TtsManager._restart` 里本来就是 `unawaited(requestFocus())`，这里对齐。
  @override
  Future<void> play() async {
    MediaKeyState.noteSessionAction('play');
    // ★v1.21.54 诊断：把「这一拍播放究竟派发给谁」一次打全。
    //
    // 用户报「书A暂停 → 打开书B → 恢复却读书A」，但纯 Dart 层已实测 A 完全脱离
    // （`_speaking=false`、PDF 会话 `isPlaybackActive=false`、`_source` 已切到
    // tts-manager）。所以真凶在本层之外，必须靠真机日志定位。
    //
    // 这里一次记全 5 个量，**任意一条日志都能直接读出"这一下会不会读 A"**：
    //   · source     —— 命令派发给了谁（tts-manager / pdf-session）；
    //   · title      —— 那个来源自己认为在读哪本书；
    //   · docId      —— 来源持有的文档 id；
    //   · playing/paused —— 走的是"接着播"还是"暂停态恢复"；
    //   · sessionKey —— PDF 会话键（换书后 token 会变，能看出是不是旧会话）。
    _diag('play source=${_source.sourceId} '
        'title=${_source.documentTitle} '
        'playing=${_source.playing} paused=${_source.paused} '
        'hasSession=${_source.hasSession} '
        'ttsDoc=${_manager.activeDocumentId} '
        'pdfDoc=${PdfReadSession.instance.documentId} '
        'pdfKey=${PdfReadSession.instance.sessionKey} '
        'pdfActive=${PdfReadSession.instance.isActive} '
        'pdfPlayback=${PdfReadSession.instance.isPlaybackActive} '
        'identicalSourcePdf=${identical(_source, PdfReadSession.instance)}');
    // ⚠️ ColorOS（一加 / OPPO，实测设备 PKG110）把媒体键与通知栏按钮统一发成
    // `KEYCODE_MEDIA_PLAY`，**不发**标准的 `MEDIA_PLAY_PAUSE`。真机日志（v1.21.15）
    // 9 次按键全是 `媒体控制[play]`，其中三次发生在 `playing=true paused=false`
    // ——也就是用户按的是"暂停"。所以这里的 `play()` 实际承担"切换"职责：
    //   正在播 → 当暂停；否则 → 正常播。
    //
    // 不这么做的话，按"暂停"会走到 `playFromCursor()` = **从当前句重播**
    // （用户原话："按暂停反而重播"）。
    if (_source.hasSession && _source.playing && !_source.paused) {
      _diag('play→pause（ROM 兼容）');
      return pause();
    }
    // ★v1.21.57：当前来源**已经没有会话**时，把播放交给还活着的那个来源。
    //
    // 真机日志（2026-10-17 13:11）：
    // ```
    // 13:11:08  打开 PDF → terminateForDocumentSwitch 清空 TTS 会话
    //           pushState→idle（卡片消失）source=tts-manager hasSession=false
    // 13:11:11  按播放 → 媒体控制[play source=tts-manager … hasSession=false]
    // 13:11:11  pushState→idle（卡片消失）        ← 什么都没发生
    // ```
    // 播放键派给了一个没有会话的来源 → 完全没反应。
    //
    // ★v1.21.59：按**用户正在看哪本文档**派发，而不是"上次来源停在哪"。
    //
    // 背景（同一个问题反复出现，前几版都在"抢来源"上打转）：
    //   · 用户反馈「从上一本书，换到 pdf 时，用耳机控制启停控制的还是上一本书」
    //     —— 来源停在 tts-manager（上一本只是暂停），按耳机就继续读旧书；
    //   · 而一旦在打开页面时把来源抢给 PDF，又会把另一本的朗读停掉
    //     —— 真机反馈「耳机控制失效」「PDF 修好了，EPUB 又复发」。
    //
    // 根因：「用户在看哪本」≠「音频来源停在哪」。现在前者由阅读页显式登记
    // （`PdfReadSession.setForeground`），这里只按登记结果派发，
    // **不改动、也不依赖**当前来源。
    final pdf = PdfReadSession.instance;
    if (!identical(_source, pdf) && pdf.isActive) {
      // PDF 页在前台，或当前来源已经空了（无会话 → 按了也没反应）
      if (pdf.isForeground || !_source.hasSession) {
        _diag('play→按前台派发 pdf-session '
            '（pdfForeground=${pdf.isForeground} '
            'sourceHasSession=${_source.hasSession}）');
        activate(pdf);
      }
    }
    MediaInterruptionController.instance.notifyUserResumed();
    _source.playFromCursor();
    unawaited(MediaInterruptionController.instance.requestFocus());
    // 恢复播放也要把新状态推给通知栏（PDF 来源不走 `_sync()`，见 [syncAfterUserCommand]）
    syncAfterUserCommand();
  }

  /// 耳机 / 通知栏「暂停」：按**前台文档**派发，然后停声；**不释放音频焦点**（v1.21.15）
  ///
  /// 原来的实现暂停后就 `releaseFocus()`（`setActive(false)`）。实测（ColorOS /
  /// Android 13+）：交出焦点之后，系统**可能不再把媒体键路由给本应用** ——
  /// 表现就是「暂停之后再按播放键毫无反应」。现在暂停保留焦点，
  /// 只在 [stop] / 会话结束时释放（否则别的应用会被一直压着）。
  ///
  /// ## ★v1.21.61：派发必须与 [play] 对称
  ///
  /// 用户反馈（2026-10-17）：
  /// > 「书A朗读中 → 打开书B → 在书B界面按暂停，停的是**书A**；
  /// >   再按播放才读书B」
  ///
  /// 真机日志：
  /// ```
  /// 15:03:37  前台[PDF]=true                     ← 用户在看 PDF(书B)
  /// 15:03:40  媒体控制[pause] source=tts-manager … playing=true
  ///           → `_source.pause()` 把书A停了     ← 停错了
  /// 15:03:42  play → play→按前台派发 pdf-session  ← 要到这一步才对
  /// ```
  ///
  /// 原因：`play()` 有「按前台改写 `_source`」这一步，`pause()` 从来没有 ——
  /// 它是 v1.21.15 定稿时的直译（那时只有 TTS 一个来源，不存在派发问题）。
  ///
  /// 现在两边对称：
  ///   · 前台是 PDF → 先把来源交给 PDF（`activate` 会给旧来源发 `onStop()`，
  ///     **正在响的那本书随之停声**），再 `pause()`；
  ///   · 前台是文字档而来源还是 PDF → 反过来交回文字档。
  ///
  /// 这样「按暂停」同时满足两件事：**声音真的停** + **当前来源就是你在看的那本**，
  /// 于是紧接着按播放能直接读对书（不必按两次）。
  @override
  Future<void> pause() async {
    MediaKeyState.noteSessionAction('pause');
    _diag('pause');
    MediaInterruptionController.instance.notifyUserPaused();
    // ★按前台派发：与 [play] 的 423-432 完全对称。
    final pdf = PdfReadSession.instance;
    if (pdf.isActive) {
      if (pdf.isForeground && !identical(_source, pdf)) {
        _diag('pause→按前台派发 pdf-session（pdfForeground=true）');
        activate(pdf);
      } else if (!pdf.isForeground &&
          identical(_source, pdf) &&
          _manager.hasSession) {
        _diag('pause→按前台派发 tts-manager（pdfForeground=false）');
        activate(_manager);
      }
    }
    await _source.pause();
    // ⚠️ 暂停之后必须确认通知栏换成了"播放"图标（v1.21.39）：
    // 耳机 / 通知栏按下暂停时，来源可能不推（PDF 不挂 `_sync()` 的 listener），
    // 表现就是用户报的「耳机暂停后图标不同步」。见 [syncAfterUserCommand]。
    // （已实测：注释掉这一行，用例会红在 `playing` 仍是 true）
    syncAfterUserCommand();
  }

  @override
  Future<void> stop() async {
    MediaKeyState.noteSessionAction('stop');
    _diag('stop');
    await _manager.stop();
    await MediaInterruptionController.instance.releaseFocus();
    await super.stop();
    _started = false;
  }

  @override
  Future<void> seek(Duration position) async {
    final source = _source;
    // 来源说不能拖就不拖（PDF 会话）：这里再挡一道，
    // 免得系统在某些机型上仍然下发 seek
    if (!source.canSeek) return;
    final total = source.progressTotal;
    if (total <= 0) return;
    final fraction = position.inMilliseconds / (total * _unitMillis);
    source.seekToProgress(fraction);
  }

  /// 耳机「下一首」：**下一句**（v1.21.43 需求三：删掉「按章」分支）
  ///
  /// 原来这里有 `if (headsetNextAction == MediaKeyAction.chapter) _source.skipChapter(1);`
  /// —— 该能力已整体删除（枚举 / 设置项 / UI / 存档键全清），
  /// 耳机键**固定按句**。通知栏的三个按钮仍只有
  /// `skipToPrevious / play|pause / skipToNext`，语义不变。
  @override
  Future<void> skipToNext() async {
    MediaKeyState.noteSessionAction('next');
    _diag('skipToNext');
    _source.skipSentenceForward();
  }

  /// 耳机「上一首」：**上一句**（同上，删掉「按章」分支）
  @override
  Future<void> skipToPrevious() async {
    MediaKeyState.noteSessionAction('previous');
    _diag('skipToPrevious');
    _source.skipSentenceBackward();
  }

  /// 长按快进（部分耳机与车机把长按映射到这里）：一次一段
  // ⚠️ v1.21.43 需求三：这里原来还有 `fastForward()` / `rewind()` 两个覆写，
  // 它们**只调 `_source.skipPageForward()` / `skipPageBackward()`** —— 而那两个
  // 在 PDF 侧就是 `skipChapter(±1)` 的薄包装。**通知栏从来不发这两个动作**
  // （只有 `skipToPrevious / play|pause / skipToNext`，见本文件 :225 的说明），
  // 所以它们是**不可达代码**，已删。
  //
  // ⚠️ **没有一并删** `AudioSessionSource.skipPageForward/Backward` 与
  // `TtsManager.skipPageForward/Backward`：它们被 **5 个测试文件**直接调用
  // （`reader_features_test` / `device_verify_test` / 两个 media_* stub 等），
  // 删掉会连带改测试。**稳定优先，留给 S3 一起清**（见交接文档"已知未做"）。
}
