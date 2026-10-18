import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/pdf_reading/pdf_read_session.dart';
import '../tts/tts_manager.dart';
import 'wave_progress.dart';

/// 控制栏的**数据来源视图**：把两个平行会话抹平成同一组字段。
///
/// 这一层是 v1.21.1「控制栏双源分派」的核心：
///
/// | 会话 | 位置 | 「下一句」 | 方块键（停止） |
/// | --- | --- | --- | --- |
/// | [TtsManager]（TXT / EPUB） | 结构化文档游标 | 文档游标 +1 句 | `endSessionAndClear()`（**整条消失**） |
/// | [PdfReadSession]（PDF） | `PdfSentenceRef` | 会话推进 | `stopSound()` + 只让阅读页收起成小条 |
///
/// ⚠️ 两条的方块键语义**故意不同**（HANDOFF §4.92）：文档库这条是
/// 「终止朗读 + 关闭控制栏，回到刚打开软件的样子」；PDF 那边是
/// 「停声 + 收起成 46dp 迷你条，会话保留」。别顺手改成一样。
class _BarSource {
  const _BarSource({
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.canResume,
    required this.onPlayPause,
    required this.onNextSentence,
    required this.onStop,
    this.progress = 0,
    this.progressLabel,
    this.documentId,
  });

  final String title;
  final String subtitle;
  final bool playing;

  /// 0~1，喂给波浪进度条
  final double progress;

  /// 进度旁的小字（如 `128 / 328`）；null 表示不显示
  final String? progressLabel;

  /// 当前在读的文档 id：用来查封面（`coverPathOf`）
  final String? documentId;

  /// 暂停之后能不能「继续」（PDF 会话在末句读完时不能）
  final bool canResume;

  final VoidCallback onPlayPause;
  final VoidCallback onNextSentence;
  final VoidCallback onStop;
}

/// 底部可折叠的朗读控制栏（放在「导入文件」左侧）
///
/// - 收起：一张碟片（正在朗读时缓慢旋转，暂停/停止时停住）；
/// - 展开：在按钮左侧铺开一条胶囊形控制栏 —— 播放/暂停、下一句、
///   返回朗读页、停止、收起箭头。
///
/// 什么都没在读的时候（两个会话都不活跃）整条不显示：那四个按钮本来也没有意义。
///
/// 只监听 [TtsManager] 与 [PdfReadSession]，不要在外层用 `context.watch` ——
/// 朗读时管理器每句都会发通知，外层跟着重建会把文档库列表也一起重建。
class ReadingControlBar extends StatefulWidget {
  const ReadingControlBar({
    super.key,
    required this.onReturnToReading,
    this.onOpenSettings,
    this.coverPathOf,
  });

  /// 「返回朗读页」：跳回正在朗读的那本书（没在读整本书时调用方自己给提示）
  final Future<void> Function() onReturnToReading;

  /// 跳设置页（现在条上不占键位，保留给以后的入口）
  final void Function()? onOpenSettings;

  /// 按文档 id 查封面文件路径（文档库有现成的 `coverPath`）；查不到用占位图
  final String? Function(String? documentId)? coverPathOf;

  /// 展开态的齿轮按钮（设置）
  static const Key settingsKey = ValueKey<String>('reading-settings');

  /// 收起态的碟片（测试用；tooltip 会随播放状态变，不适合当锚点）
  static const Key discKey = ValueKey<String>('reading-disc');

  /// 展开态的控制栏
  static const Key barKey = ValueKey<String>('reading-bar');

  /// 「停止」方块键：结束朗读（用户明确要求保留这个语义）
  static const Key stopKey = ValueKey<String>('reading-stop');

  /// 「返回朗读页」定位键
  static const Key returnKey = ValueKey<String>('reading-return');

  /// 诊断日志开关（**第 0 步排查用**；正式版留着无害，默认关）
  ///
  /// 控制栏的问题是「按了没反应」，而它的动作分派在 `_pickSource` 里按来源
  /// 走不同分支 —— 光看界面分不出「没派发」还是「派发了但被吞」。
  /// 打了标签就能一眼看出走的是 TXT 还是 PDF 那条路。
  static bool debugLog = false;

  /// 诊断输出（同时进 `debugPrint` 与 [debugRecent]，测试可直接断言）
  static void diagnose(String message) {
    debugRecent.add(message);
    if (debugRecent.length > 50) debugRecent.removeAt(0);
    if (debugLog) debugPrint('[控制栏] $message');
  }

  /// 最近若干条诊断（**只给测试看**）
  @visibleForTesting
  static final List<String> debugRecent = <String>[];

  @override
  State<ReadingControlBar> createState() => _ReadingControlBarState();
}

class _ReadingControlBarState extends State<ReadingControlBar>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 碟片旋转：6 秒一圈，转起来有「在放」的感觉又不晃眼
  ///
  /// 必须在 initState 里建：用 `late final ... = AnimationController(...)` 的话，
  /// 没有朗读会话时（build 里提前 return，从没碰过这个字段）它会在 **dispose 时**
  /// 才被初始化，那时 element 已经失活，`createTicker` 查 TickerMode 会直接断言失败。
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  /// 启停旋转（repeat / stop 只通知动画监听者，不会让本 State 重建）
  void _syncSpin({required bool playing, required bool reduceMotion}) {
    final want = playing && !reduceMotion;
    if (want && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!want && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TtsManager>(
      builder: (context, tts, _) {
        // PDF 会话是平行单例（不是 Provider），用 ListenableBuilder 单独听它
        return ListenableBuilder(
          listenable: PdfReadSession.instance,
          builder: (context, _) {
            final source = _pickSource(tts);
            if (source == null) return const SizedBox.shrink();
            _syncSpin(
              playing: source.playing,
              reduceMotion: MediaQuery.of(context).disableAnimations,
            );
            return AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerRight,
              child: _expanded
                  ? _expandedBar(context, source)
                  : _disc(context, source),
            );
          },
        );
      },
    );
  }

  /// 决定控制栏现在代表哪个会话
  ///
  /// PDF 优先：用户在读 PDF 时又去文档库点了 TXT，[TtsManager] 会通过
  /// `activate` 把 PDF 会话顶掉（双向换书终止），所以两个同时活跃是瞬态；
  /// 真撞上时以 PDF 为准（它的位置更「重」，用户刚看过那一页）。
  _BarSource? _pickSource(TtsManager tts) {
    final pdf = PdfReadSession.instance;
    // ignore: avoid_print
    // ⚠️ §4.103：判据是 **isPlaybackActive**（存在 && 在播/暂停），不是 isActive。
    //
    // §4.100 原以为「两源同时活跃只是瞬态，真撞上以 PDF 为准」——实测这个前提
    // **不成立**：`stopSound()` 为了「换歌记住进度」故意保留会话，于是
    // 「PDF 被 TXT 顶停」之后 `isActive` 仍为 true，这里就会一直返回 PDF 分支
    // → 控制栏显示、按钮绑定的是**已经停掉的那本 PDF**（用户报的「绑错文档」）。
    //
    // 判据拆开：**显示**看「是不是在播」；**方块键清理**看「会话在不在」（见
    // `_stopEverything`，那里保持 isActive 不变）。
    final pdfPlayback = pdf.isPlaybackActive;
    ReadingControlBar.diagnose(
      '求值 ttsActive=${tts.hasSession}(doc=${tts.activeDocumentId}) '
      'pdfActive=$pdfPlayback(doc=${pdf.documentId} '
      'isActive=${pdf.isActive}) '
      '→ 取=${pdfPlayback ? "PDF" : (tts.hasSession ? "TTS" : "无(整条隐藏)")}',
    );
    if (pdfPlayback) {
      return _BarSource(
        title: pdf.documentTitle.isEmpty ? '未命名 PDF' : pdf.documentTitle,
        subtitle: pdf.positionLabel.isEmpty ? '—' : pdf.positionLabel,
        playing: pdf.isPlaying,
        canResume: pdf.current != null,
        progress: pdf.pageCount <= 0
            ? 0
            : ((pdf.progressIndex + 1) / pdf.pageCount).clamp(0.0, 1.0),
        progressLabel: pdf.pageCount <= 0
            ? null
            : '${pdf.progressIndex + 1} / ${pdf.pageCount}',
        documentId: pdf.documentId,
        onPlayPause: () {
          // ★v1.21.54 诊断：与 `TtsAudioHandler.play()` 那条对齐，一次记全。
          // 用户报「切书后播放读回旧书」，两入口都要能一眼看出"这一下读了谁"。
          ReadingControlBar.diagnose(
              '播放/暂停 → PDF ${pdf.isPlaying ? "pause" : "resume"} '
              'doc=${pdf.documentId} title=${pdf.documentTitle} '
              'playing=${pdf.isPlaying} paused=${pdf.isPaused} '
              'block=${pdf.positionLabel} '
              'ttsDoc=${tts.activeDocumentId} ttsTitle=${tts.documentTitle} '
              'ttsHasSession=${tts.hasSession}');
          if (pdf.isPlaying) {
            unawaited(pdf.pause());
          } else {
            pdf.resume();
          }
        },
        onNextSentence: () {
          ReadingControlBar.diagnose('下一句 → PDF skipSentenceForward');
          pdf.skipSentenceForward();
        },
        // ⚠️ 这里是**文档库**的方块键：语义必须是「整条消失」（§4.92），
        // 所以走 `clear()`（会清会话 + 让控制栏隐藏）。
        // 走 `stopSound()` 只停声、会话还在 → 碟片留着不走，
        // 正是用户报的「方块键按了朗读不停、控制栏不消失」。
        onStop: () => _stopEverything(tts, pdf),
      );
    }
    if (!tts.hasSession) return null;
    // 「只有在读的时候才显示」：阅读页按方块键结束朗读后 `stop()` 只停声、
    // 故意留着会话记进度（`hasSession` 仍为真）。只按 hasSession 判断的话，
    // 结束朗读后这条会一直挂在文档库上不消失（用户报的现象）。
    if (tts.endedByStop) {
      ReadingControlBar.diagnose('TTS 已被用户结束朗读（endedByStop）→ 整条隐藏');
      return null;
    }
    return _BarSource(
      title: tts.documentTitle.isEmpty ? '未命名文档' : tts.documentTitle,
      subtitle: tts.currentChapterTitle.isNotEmpty
          ? tts.currentChapterTitle
          : (tts.positionLabel.isNotEmpty ? tts.positionLabel : '—'),
      playing: tts.playing,
      canResume: true,
      progress: tts.progress,
      progressLabel: tts.progressTotal <= 0
          ? null
          : '${tts.progressIndex} / ${tts.progressTotal}',
      documentId: tts.activeDocumentId,
      onPlayPause: () {
        // ★v1.21.54 诊断：同上，TTS 分支也要能一眼看出"这一下读了谁"。
        ReadingControlBar.diagnose(
            '播放/暂停 → TTS ${tts.playing ? "pause" : "playFromCursor"} '
            'doc=${tts.activeDocumentId} title=${tts.documentTitle} '
            'speaking=${tts.speaking} paused=${tts.paused} '
            'cursor=${tts.cursor} '
            'pdfDoc=${PdfReadSession.instance.documentId} '
            'pdfPlayback=${PdfReadSession.instance.isPlaybackActive}');
        if (tts.playing) {
          unawaited(tts.pause());
        } else {
          tts.playFromCursor();
        }
      },
      onNextSentence: () {
        ReadingControlBar.diagnose('下一句 → TTS skipSentenceForward');
        tts.skipSentenceForward();
      },
      // 方块键 = 终止朗读**并关闭控制栏**（回到刚打开软件的样子）
      onStop: () => _stopEverything(tts, pdf),
    );
  }

  /// **文档库控制栏的方块键：一次按下去，两个会话一起清**（§4.101 任务 F）
  ///
  /// ## 为什么不能只清「当前显示的那一个」
  ///
  /// 应用内有**两个**互相独立的播放开关：
  ///   · 开关 A = `TtsManager` 的会话（TXT / EPUB / 纯文本）
  ///   · 开关 B = `PdfReadSession` 的会话（PDF）
  ///
  /// 而 [_pickSource] 是**提前 return 的单边结构**（PDF 优先，命中就不再往下走），
  /// 于是方块键只清了当前那一个来源。两个会话同时活跃时就会出现用户报的
  /// 「按一次声音停了、控制栏不消失，要再按一次」——不是没生效，是**只关了一半**：
  /// 第一次清掉 PDF，控制栏因为 `tts.hasSession` 仍为真而留着；
  /// 第二次才轮到 TTS 分支。
  ///
  /// 所以这里**两个都清**，与「当前显示的是哪一个」无关。两边都自带空操作保护：
  /// `TtsManager.endSessionAndClear()` 在没有文档时是安全的，
  /// `PdfReadSession.clear()` 在没有会话时也会安全返回。
  ///
  /// ## ⚠️ 顺序：必须先清 PDF，再清 TTS
  ///
  /// PDF 是**借** `TtsManager` 发声的，而 `PdfReadSession.clear()` 内部
  /// `_flushSpot()` 之后会调 `TtsManager.stop()`。若先清 TTS，那条链会把
  /// PDF 会话也一并收尾，PDF 最后的位置就可能来不及落盘（§4.100 任务 E 的
  /// 「换歌要记住进度」同一条要求）。
  ///
  /// ## 通知栏
  ///
  /// 本轮（v1.21.13 简化需求）撤销了「卡片保留 + 未在播放」的中间态：
  /// 清掉两个会话后 **不再** 显式推通知栏 —— `TtsManager.endSessionAndClear()`
  /// 会自然触发 `_sync()` → `_pushState()` → `processingState = idle`，
  /// audio_service 按默认行为把卡片收掉（这正是新需求的语义）。
  void _stopEverything(TtsManager tts, PdfReadSession pdf) {
    ReadingControlBar.diagnose(
        '方块键 → 清两个会话（pdfActive=${pdf.isActive} '
        'ttsActive=${tts.hasSession}，先 PDF 后 TTS）');
    if (pdf.isActive) unawaited(pdf.clear());
    unawaited(tts.endSessionAndClear());
  }

  /// 展开态：**一条**（封面 | 书名 + 波浪进度 | 停止 · 设置 · 播放）
  ///
  /// 2026-10-18 按用户要求放大触控区：条高 76、按键 48dp、间距 12dp
  /// （原来是 34dp / 间距 6，容易误触）。收起不再占键位——再点一次封面就收起。
  Widget _expandedBar(BuildContext context, _BarSource source) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playing = source.playing;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // 宽度上限 420（2026-10-18 从 560 收窄）：560 时竖屏占屏 73%、横屏左边空一大块，
    // 420 既放得下「封面+书名+进度+三个 48dp 键」，又不会显得糊在屏幕上。
    final barWidth = (screenWidth - 32).clamp(240.0, 420.0);

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
      child: SizedBox(
        width: barWidth,
        height: 76,
        child: Material(
          key: ReadingControlBar.barKey,
          color: scheme.surfaceContainerHigh,
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                // 封面：点它收起回小方块（热区 48dp）。
                // 「返回朗读页」放在右边书名/进度那块 —— 文字区本来就宽，好点。
                InkWell(
                  key: ReadingControlBar.discKey,
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => setState(() => _expanded = false),
                  child: _cover(
                    scheme,
                    playing: playing,
                    size: 48,
                    path: widget.coverPathOf?.call(source.documentId),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    key: ReadingControlBar.returnKey,
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => unawaited(widget.onReturnToReading()),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          source.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        WaveProgressBar(
                          value: source.progress,
                          label: source.progressLabel,
                          height: 12,
                          playing: playing,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _gearButton(
                  size: 44,
                  tooltip: '下一句',
                  icon: Icons.fast_forward,
                  onPressed: source.onNextSentence,
                ),
                const SizedBox(width: 12),
                _gearButton(
                  key: ReadingControlBar.stopKey,
                  size: 44,
                  tooltip: '停止并结束朗读',
                  icon: Icons.stop,
                  // 方块键：TXT 是「终止并清空」、PDF 是「只停声」
                  //（语义由 _pickSource 决定，见 _BarSource 的说明）
                  onPressed: source.onStop,
                ),
                const SizedBox(width: 12),
                _gearButton(
                  size: 52,
                  tooltip: playing ? '暂停' : '播放',
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  onPressed: source.onPlayPause,
                  emphasized: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 封面：有真实封面就用图，否则退回占位色块 + 书本图标
  Widget _cover(ColorScheme scheme, {required bool playing, required double size, String? path}) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.primaryContainer,
            scheme.primaryContainer.withOpacity(0.55),
          ],
        ),
      ),
      child: Icon(Icons.menu_book, size: size * 0.5, color: scheme.onPrimaryContainer),
    );
    if (path == null || path.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 只解码缩略图大小，别为大图掉帧
        cacheWidth: 160,
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }

  /// 收起态：**只有一枚封面方块**（用户要求：收起只显示封面）
  ///
  /// 点它向左展开成 M1 那条；播放/暂停留给展开态，收起态不做第二件事。
  Widget _disc(BuildContext context, _BarSource source) {
    final scheme = Theme.of(context).colorScheme;
    final playing = source.playing;

    return Tooltip(
      key: ReadingControlBar.discKey,
      message: playing ? '正在朗读 · 点击展开控制栏' : '朗读已暂停 · 点击展开控制栏',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SizedBox(
          width: 56,
          height: 56,
          child: Material(
            color: scheme.surfaceContainerHigh,
            elevation: 4,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _expanded = true),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: _cover(
                  scheme,
                  playing: playing,
                  size: 44,
                  path: widget.coverPathOf?.call(source.documentId),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 齿轮边圆形键（形状 + 配色都照用户给的参考图）
  ///
  /// 参考图：**浅灰齿轮 + 深色图标**，播放键是**深灰实心齿轮 + 白色图标**、大一号。
  /// 颜色**不跟主题走**（用户明确要参考图那个配色），只按亮/暗主题微调一档明度，
  /// 保证深色条上也能看清形状。
  Widget _gearButton({
    Key? key,
    required double size,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool emphasized = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 浅灰齿轮：暗色主题下稍微提亮，避免和 #2C2C32 的条底糊在一起
    final pale = dark ? const Color(0xFFD6D8DE) : const Color(0xFFDDE1E5);
    const ink = Color(0xFF1C1C20);
    // 播放键：深灰实心 + 白图标（暗色主题下用更浅一档，不然整个看不见）
    final strong = dark ? const Color(0xFF8A94A3) : const Color(0xFF56606A);
    const onStrong = Color(0xFFFFFFFF);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _GearPainter(
                fill: emphasized ? strong : pale,
                stroke: emphasized ? null : ink.withOpacity(0.10),
                strokeWidth: 1.5,
              ),
            ),
          ),
          IconButton(
            key: key,
            tooltip: tooltip,
            onPressed: onPressed,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: Icon(
              icon,
              size: size * 0.46,
              color: emphasized ? onStrong : ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// 齿轮边（12 波瓣）：可以填充，也可以只描边
class _GearPainter extends CustomPainter {
  const _GearPainter({
    required this.fill,
    this.stroke,
    this.strokeWidth = 1.5,
  });

  final Color fill;
  final Color? stroke;
  final double strokeWidth;

  static const int lobes = 12;
  static const double depth = 0.085;

  static Path path(Size size, {double inset = 0}) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy) - inset;
    final path = Path();
    for (int i = 0; i <= 360; i += 3) {
      final a = i * math.pi / 180;
      final rr = r * (1 - depth + depth * math.cos(lobes * a));
      final x = cx + rr * math.cos(a);
      final y = cy + rr * math.sin(a);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = path(size, inset: 1);
    canvas.drawPath(p, Paint()..color = fill);
    final s = stroke;
    if (s != null) {
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = s,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GearPainter old) =>
      old.fill != fill || old.stroke != stroke || old.strokeWidth != strokeWidth;
}
