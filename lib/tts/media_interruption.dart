import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../services/crash_log.dart';
import '../services/storage_service.dart';

/// 朗读的音频焦点与打断处理
///
/// **为什么要这个**：原来只在启动时 `session.configure(speech())` 配了音频属性，
/// 但**从来没有 `setActive(true)`** —— 也就是从没申请过音频焦点。
/// 结果就是两个都不对：
/// - 别的应用出声时，系统不会把我们压低 / 暂停（听书和音乐一起响）；
/// - 来电、闹钟也不会把我们暂停。
///
/// 现在按用户的开关决定：
/// - **允许其它媒体打断**（默认开）：朗读时申请音频焦点，接受系统的
///   duck（压低）/ pause（暂停）/ 来电中断；对方结束或挂断后**自动继续**；
/// - **关掉**：不申请焦点，谁也不打扰谁（想边听书边放音乐时用）。
///
/// 「自动继续」只对**系统要求我们暂停**的情况生效；用户自己按的暂停不会被打断逻辑
/// 重新拉起来（用 [notifyUserPaused] / [notifyUserResumed] 区分）。
class MediaInterruptionController {
  MediaInterruptionController._();

  static final MediaInterruptionController instance = MediaInterruptionController._();

  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _sub;
  bool _initialized = false;

  /// 用户主动暂停过：这种情况下不自动继续
  ///
  /// ⚠️ **它必须能被"开始朗读"清掉**（v1.21.49 修）：这是个**粘性**标志，
  /// 只有通知栏 / 耳机的播放键会清它（`notifyUserResumed`）。用户在**应用内**
  /// 点播放走的是 `TtsManager._restart`，不经过那条路 —— 于是"很久以前按过一次
  /// 暂停"会一直留成 true，把**短打断自动接回**那条路也一起堵死。
  /// 真机日志（2026-10-14 23:05）里就是 `userPaused=true` 而用户正在听。
  bool _userPaused = false;

  /// 本轮打断里我们**是否真的暂停过**
  ///
  /// `false` = 那次打断是"瞬时"类型（微信通知）→ **朗读全程没停**，
  /// 结束时什么都不用做。这是本设计要保住的"成功路径"。
  bool _pausedForInterruption = false;

  /// 朗读真正开始 / 继续时调用：申请音频焦点（受开关控制）
  ///
  /// 返回是否真的拿到了焦点。拿不到（例如别的应用正占着且不让）也照常朗读 ——
  /// 不给用户「点了没声音」的困惑。
  Future<bool> requestFocus() async {
    await _ensureInit();
    if (!StorageService.instance.allowMediaInterrupt) return false;
    final session = _session;
    if (session == null) return false;
    try {
      final ok = await session.setActive(true);
      if (!ok) {
        CrashLog.mark('音频焦点申请失败：被其它应用占用');
      }
      return ok;
    } catch (e) {
      CrashLog.mark('音频焦点申请异常：$e');
      return false;
    }
  }

  /// 朗读暂停 / 停止 / 结束时调用：释放音频焦点
  ///
  /// 必须释放：不释放的话别的应用会被我们一直压着（用户会以为音乐坏了）。
  ///
  /// ⚠️ v1.21.15：**暂停不再走这里**（只在停止 / 会话结束时释放）。
  /// 实测（ColorOS / Android 13+）：暂停时 `setActive(false)` 会把会话的音频焦点
  /// 交出去，之后再按耳机/通知栏的「播放」，系统可能**不再把媒体键路由给我们**
  /// ——表现就是「按了没反应」。代价：暂停期间仍占着焦点（别人会继续被压低）。
  Future<void> releaseFocus() async {
    _releaseFocusCount++;
    final session = _session;
    if (session == null) return;
    try {
      await session.setActive(false);
    } catch (_) {
      // 释放失败不影响功能
    }
  }

  int _releaseFocusCount = 0;

  /// 测试用：releaseFocus 被调用的次数（锁住"暂停不释放焦点"这条行为）
  @visibleForTesting
  int get debugReleaseFocusCount => _releaseFocusCount;

  /// 用户主动暂停（按了暂停键）
  void notifyUserPaused() => _userPaused = true;

  /// 用户主动继续（按了播放键）
  ///
  /// ⚠️ **必须同时清掉"已让位"标志**（v1.21.52 真机日志暴露的 bug）：
  /// 用户手动恢复播放后，那次打断就算**翻篇了**；若不清，标志会一直留成 true，
  /// 于是**下一次打断**（哪怕是视频）会走进"已经让位过了 → 不重复处理"那一支，
  /// **不再让位** —— 用户最在意的"视频必须让位"就失效了。
  ///
  /// 真机日志（2026-10-15 00:25）里的形态：
  /// ```
  /// 00:25:39  视频 → 让位暂停（pausedForIt=true）
  /// 00:25:55  用户手动点播放恢复            ← 此处标志没被清
  /// 00:26:30  通知来了 → "已经让位暂停过了 → 不重复处理"（用的是旧标志）
  /// ```
  void notifyUserResumed() {
    _userPaused = false;
    _pausedForInterruption = false;
    // v1.22.37: interruption ended -> take audio focus back,
    // otherwise the session stays PAUSED and Android removes us from
    // media-button routing (no headset / no notification control until restart).
    unawaited(requestFocus());
  }

  /// 开关变化后重新配置音频属性
  ///
  /// 「允许打断」时用 `speech()`（会自动在被打断 / 被压低时暂停）；
  /// 不允许时用 `music()` 的 gain 策略 —— 只是出声，不去抢焦点。
  Future<void> applySettings() async {
    await _ensureInit();
    final session = _session;
    if (session == null) return;
    try {
      await session.configure(_configuration());
    } catch (_) {
      // 配置失败沿用上一次
    }
  }

  /// 音频会话配置
  ///
  /// ## ⚠️ `androidWillPauseWhenDucked` 必须保持 `true`（v1.21.39 回退记录）
  ///
  /// v1.21.38 为了「朗读不被通知打断」，把两种模式都改成了 `false`。
  /// **那是个错误**，真机反馈：**「被视频打断」功能失效，而且通知栏图标变得不对**。
  ///
  /// 原因：这个开关不是"允许被压低音量"那么简单 —— 它是**整个停止上报 duck 事件**。
  /// 而系统提示音与视频播放走的是**同一条 duck 路径**，所以关掉之后：
  ///
  /// | | 系统提示音 | 视频 / 其它播放器 |
  /// | --- | --- | --- |
  /// | 期望 | 继续朗读 | **暂停** |
  /// | `false` 时 | 继续朗读 ✓ | **也继续朗读 ✗** |
  ///
  /// 于是"该让位时也不让位"：焦点状态与实际出声不一致，通知栏也随之错乱。
  /// **一个布尔值区分不了"提示音"与"视频"** —— 想要两者兼顾，
  /// 得在原生侧区分 `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`（提示音）
  /// 与 `AUDIOFOCUS_LOSS` / `LOSS_TRANSIENT`（视频 / 来电），属于平台通道改动，
  /// **本轮不做**。所以这里回到 `true`：**宁可被提示音打断，也不能不让位给视频**。
  AudioSessionConfiguration _configuration() {
    if (StorageService.instance.allowMediaInterrupt) {
      return const AudioSessionConfiguration.speech();
    }
    // 不抢焦点模式：gainTransientMayDuck 会让我们的声音被别人的 duck 影响，
    // 这里用普通的媒体属性，互不干扰。
    return const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: true,
    );
  }

  /// 当前音频会话配置（**只给测试看**）
  ///
  /// 用它钉住一条硬要求：「**朗读不被通知打断**」——
  /// 也就是两种模式下 `androidWillPauseWhenDucked` 都必须是 `false`
  /// （true = 系统提示音一 duck 就把我们暂停，见 [_configuration] 的说明）。
  @visibleForTesting
  AudioSessionConfiguration get debugConfiguration => _configuration();

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final session = await AudioSession.instance;
      _session = session;
      await session.configure(_configuration());
      // 打断事件：系统的 duck / pause / 来电都在这里
      _sub = session.interruptionEventStream.listen(_onInterruption);
    } catch (e) {
      CrashLog.mark('音频会话初始化失败：$e');
    }
  }

  /// 系统打断事件
  ///
  /// ## 三类事件怎么分（v1.21.39）
  ///
  /// | 事件 | 来源 | 我们的动作 |
  /// | --- | --- | --- |
  /// | `duck` + `begin` | **系统提示音** / 导航播报（瞬时） | 先让位暂停，等 [shortDuckResumeDelay] 后**没人接着出声就自动接回** |
  /// | `pause` + `begin` | **视频 / 音乐 / 来电**（持续占用焦点） | 暂停并保持（这才是用户要的"被视频打断"） |
  /// | `begin == false` | 对方结束 | 只有「系统让停的」且用户没自己按过暂停才继续 |
  ///
  /// ### 为什么 duck 也要真暂停（而不是只被压低音量）
  ///
  /// v1.21.38 曾把 `androidWillPauseWhenDucked` 改成 `false`（想让提示音完全不打断），
  /// 结果真机反馈「**被视频打断功能失效，通知栏图标也错了**」——
  /// 因为那个开关会**整个停掉 duck 事件上报**，而视频与提示音走的是同一条 duck 路径，
  /// 于是该让位时也不让位了。
  ///
  /// ### v1.21.50（用户拍板方案一）：先别暂停，用宽限期区分
  ///
  /// v1.21.49 的"暂停 → 短的就接回"仍然让用户觉得**被打断**：接回时
  /// **Android TTS 只能把这一句从头重发**（没有从半句续读的能力），
  /// 用户原话是「老是打断重新开始读这句话太影响使用体验」。
  /// 于是 v1.21.50 改成"先不暂停，2 秒内结束就当没发生"。
  ///
  /// ### v1.21.51（用户拍板方案三）：**改成按类型分流，去掉延迟**
  ///
  /// 宽限期虽然解决了"通知打断"，但**视频要等满 2 秒才让位**（用户实测反馈）。
  /// 真机取证（2026-10-15 00:10）发现**类型本来就不同**：
  /// 通知 = `pause`（1.1 秒后有结束事件），视频 = `unknown`（永远没有结束事件）。
  /// 于是改成按类型即时分流，两类都立刻响应 —— 详见 [_pausedForInterruption] 上方
  /// 那段说明与 `audio_session` 的源码依据。
  void _onInterruption(AudioInterruptionEvent event) {
    final handler = onInterruption;
    if (handler != null) {
      handler(event);
      return;
    }

    // ★诊断（v1.21.48）：打断这条链以前**一条日志都没有**，真机上
    // "被通知打断后不读了"到底是"没收到事件"还是"收到了没接回"无从判断。
    // 这几行是给真机取证用的，成本极低（一次字符串拼接）。
    CrashLog.mark('音频打断[收到] type=${event.type.name} begin=${event.begin} '
        'pausedForIt=$_pausedForInterruption userPaused=$_userPaused');

    if (event.begin) {
      // ⚠️ **同一类事件可能连着来**（通知响完接视频）：保持"已让位"这个事实，
      // 不要因为新事件是"可以忽略的类型"就把之前的让位状态抹掉。
      if (_pausedForInterruption) {
        CrashLog.mark('音频打断[收到·开始] 已经让位暂停过了 → 不重复处理');
        return;
      }

      // ★★ v1.21.51 核心：**按类型分流，不再靠时长猜**（用户拍板的方案三）
      //
      // 真机取证（2026-10-15 00:10）拿到了决定性的类型差异：
      //   微信通知 → `type=pause`，且 1.1 秒后有 `begin=false`
      //   播放视频 → `type=unknown`，且**永远没有** `begin=false`
      //
      // 与 audio_session 0.1.25 的源码逐条对上（`lib/src/core.dart:254-283`）：
      //   `lossTransient` / `lossTransientCanDuck` → `pause` / `duck`（瞬时，会结束）
      //   `loss`（**永久**失去焦点）             → `unknown`（不会再有"结束"事件）
      // 而 `unknown` 在 Android 上**只有 `loss` 这一个来源**（另两处在 iOS 分支）。
      //
      // 这也解释了"视频为什么没有结束事件"：原生在 `AUDIOFOCUS_LOSS` 时会
      // `abandonAudioFocus()`（`AndroidAudioManager.java:307`）—— 我们不再持有焦点，
      // 系统自然不会再通知我们"对方结束了"。
      //
      // 于是判据变成**确定性的**：
      //   * `unknown`（永久失去）→ 立刻让位暂停；
      //   * `pause` / `duck`（瞬时）→ **不暂停**（朗读继续，用户要的"不打断"）。
      //
      // 为什么瞬时的那类可以放心不暂停：通知只响一下，我们不停也就无所谓"让位"；
      // 而真要长期占用焦点的场景（视频 / 来电）报的是 `loss` → 走上面那支。
      final bool permanent = event.type == AudioInterruptionType.unknown;
      if (permanent) {
        CrashLog.mark('音频打断[开始·永久失去焦点] → 立刻让位暂停');
        _pausedForItNow();
        return;
      }

      CrashLog.mark('音频打断[开始·瞬时让位 type=${event.type.name}] '
          '→ **不暂停**（朗读继续，不重读）');
      return;
    }

    // 对方结束（只有"瞬时"那类才会走到这里；`loss` 那次不会再有结束事件）
    final bool hadPaused = _pausedForInterruption;
    _pausedForInterruption = false;
    if (!hadPaused) {
      CrashLog.mark('音频打断[结束] 之前没暂停过 → 什么都不用做（朗读全程未中断）');
      return;
    }

    // 之前已让位：只重推状态，不自动接回（视频结束要不要续读是另一条线）
    final notify = notifyAfterInterruptionEnded;
    CrashLog.mark('音频打断[结束] 之前已让位暂停，只重推状态、不接回朗读'
        '（${notify == null ? "没有重推回调（!）" : "重推"}）');
    if (notify != null) unawaited(notify());
  }

  /// 真正让位暂停（永久失去焦点：视频 / 来电）
  void _pausedForItNow() {
    _pausedForInterruption = true;
    final pause = pauseForInterruption;
    CrashLog.mark('音频打断[让位] → 暂停'
        '（${pause == null ? "没有暂停回调（!）" : "调暂停"}）');
    if (pause != null) unawaited(pause());
  }

  /// 被打断时的回调（由 TtsAudioHandler 注册：暂停朗读）
  ///
  /// ⚠️ v1.21.50 起它**不再在打断一开始就调用** —— 只在"宽限期到点、对方仍在出声"
  /// 时才调（见 [_onInterruption]）。也就是说：微信通知那种一两秒的打断
  /// **永远不会走到这里**，朗读全程不中断。
  Future<void> Function()? pauseForInterruption;

  /// 打断结束时的回调（由 TtsAudioHandler 注册：继续朗读）
  ///
  /// ⚠️ v1.21.50 起**基本不再使用**：新设计下"短暂打断根本不暂停"，
  /// 所以没有"接回"这回事；真的长打断（视频 / 来电）按既有设计也**不自动接回**
  /// （只重推状态，见 [notifyAfterInterruptionEnded]）。
  /// 保留它是为了不破坏既有接线与用例，将来若要"长打断结束自动接回"还能用。
  Future<void> Function()? resumeAfterInterruption;

  /// **长打断结束**时的回调：只重推播放状态，**不动播放**
  ///
  /// ## 治什么（v1.21.45 改动 1 · 耳机键路由）
  ///
  /// 真机现象：别的应用抢走音频焦点之后，**耳机键失效** ——
  /// 而应用内按钮、通知栏按钮都还正常。怀疑系统在长打断期间把我们
  /// 从"活跃媒体"里摘掉了，于是媒体键不再路由到我们。
  ///
  /// 长打断结束时重推一次 `playbackState`，让系统重新把我们标成活跃媒体。
  /// **刻意不自动恢复朗读**：长打断（视频 / 来电）结束后要不要接着读，
  /// 是另一条独立问题链（本轮明确暂缓）。
  ///
  /// ⚠️ 这是**第一轮尝试**，根因未定性。真机验收要点：
  /// 1. 长打断结束后日志里应有 `媒体控制[pushState]`；
  /// 2. 若日志有、耳机键仍无效 → 重推状态不足以改路由，下一步动焦点策略
  ///    （暂停释放 / 播放申请 / `MediaSession.setActive(true)`），见交接文档。
  Future<void> Function()? notifyAfterInterruptionEnded;

  /// 外部（测试）接管打断事件
  @visibleForTesting
  void Function(AudioInterruptionEvent event)? onInterruption;

  /// 测试用：直接投递一个打断事件
  @visibleForTesting
  void debugInterrupt(AudioInterruptionType type, {bool begin = true}) {
    _onInterruption(AudioInterruptionEvent(begin, type));
  }

  @visibleForTesting
  bool get debugUserPaused => _userPaused;

  /// 测试用：本轮打断里我们是否真的让位暂停过
  @visibleForTesting
  bool get debugPausedForInterruption => _pausedForInterruption;

  @visibleForTesting
  void resetForTest() {
    _session = null;
    _sub?.cancel();
    _sub = null;
    _initialized = false;
    _userPaused = false;
    _pausedForInterruption = false;
    pauseForInterruption = null;
    resumeAfterInterruption = null;
    notifyAfterInterruptionEnded = null;
    onInterruption = null;
  }
}
