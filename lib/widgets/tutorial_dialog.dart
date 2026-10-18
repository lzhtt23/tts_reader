import 'dart:async';

import 'package:flutter/material.dart';

import '../services/storage_service.dart';

/// 首次使用的教程弹窗
///
/// 需求：「初次使用本软件时弹出窗口显示使用教程，阅读三秒教程后允许打勾选择
/// 不再显示」。
///
/// 两个约束都要真的做到：
/// - **三秒之后**「不再显示」才可以勾选（在此之前是禁用的，并提示还要等几秒）——
///   否则用户闭眼点一下就再也看不到教程了；
/// - 点了「不再显示」并确认后落盘，以后不再自动弹。
///
/// 关掉弹窗（点「开始使用」或返回键）但**没勾**「不再显示」时，下次还会弹 ——
/// 这是刻意的：勾选是「不再显示」的唯一开关。
class TutorialDialog extends StatefulWidget {
  const TutorialDialog({super.key});

  /// 勾选「不再显示」前必须等待的时长
  static const Duration readGate = Duration(seconds: 3);

  /// 教程内容的版本号
  ///
  /// 改动教程正文时**把它 +1**：老用户虽然勾过「不再显示」，内容版本变高后
  /// 会再看到一次新版教程（否则新功能说明永远到不了他们眼前）。
  static const int contentVersion = 2;

  /// 弹教程（已看过则直接返回 false，不弹）
  ///
  /// 返回 true 表示「用户勾了不再显示」。
  static Future<bool> maybeShow(BuildContext context) async {
    final StorageService storage = StorageService.instance;
    // 看过**且**看过的是这一版内容 → 不再打扰
    if (storage.tutorialDone && storage.tutorialContentVersion >= contentVersion) {
      return false;
    }
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const TutorialDialog(),
    );
    if (result == true) {
      await storage.setTutorialDone(true);
      await storage.setTutorialContentVersion(contentVersion);
      return true;
    }
    return false;
  }

  @override
  State<TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<TutorialDialog> {
  /// 剩余秒数（>0 时禁止勾选）
  int _remaining = TutorialDialog.readGate.inSeconds;

  /// 用户是否勾了「不再显示」
  bool _dontShowAgain = false;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 每秒递减：到 0 就放开勾选
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _remaining = _remaining > 0 ? _remaining - 1 : 0);
      if (_remaining == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _canTick => _remaining <= 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 「不再显示」故意放在**滚动区外面**（固定在按钮上方）：
    // 教程文案变长后它会被挤出可视区，用户要滚动才能看到 —— 那太容易错过。
    // 固定在底部还有个好处：3 秒倒计时的提示一直在眼前，不会被滚走。
    final dontShow = InkWell(
      onTap: _canTick ? () => setState(() => _dontShowAgain = !_dontShowAgain) : null,
      child: Row(
        children: <Widget>[
          Checkbox(
            key: const ValueKey<String>('tutorial-dont-show'),
            value: _dontShowAgain,
            onChanged: _canTick
                ? (value) => setState(() => _dontShowAgain = value ?? false)
                : null,
          ),
          Expanded(
            child: Text(
              _canTick ? '不再显示这个教程' : '读完 $_remaining 秒后可勾选「不再显示」…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _canTick ? null : scheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
    return AlertDialog(
      key: const ValueKey<String>('tutorial-dialog'),
      icon: Icon(Icons.menu_book, color: scheme.primary),
      title: const Text('欢迎使用桃花源阅读器'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _step(
              Icons.explore_outlined,
              '发现：搜书与在线书架',
              // v1.22：新增四 Tab，发现页是搜书入口
              '底部导航第二个是「发现」。点搜索框进搜索页：'
                  '顶部能改关键词，右上角「筛选」决定用哪些书源搜。\n'
                  // 聚合与排序
                  '同一本书在多个书源里都有时只显示一条，标着「N 个书源」；'
                  '名字最像的排在最前面，点开再挑一个源。\n'
                  // 详情页四键
                  '点进书籍详情页：放入书架 / 查看目录 / 书源 / 下载。\n'
                  '· 「书源」是换源：拿书名去其它源里找同一本，缺章、乱码时换一个\n'
                  '· 「下载」把整本存进文档库，进度在发现页的「下载列表」里看',
            ),
            _step(
              Icons.rss_feed,
              '订阅源（RSS）',
              '发现页搜索框右边的方形键是「导入订阅源」：'
                  '粘贴订阅源 JSON，或填订阅地址都行。\n'
                  '导入后订阅源以图标格子列在搜索框下方，点开看它列出的条目。\n'
                  // 规则失效与自动修复
                  '有些源会随站点改版失效（打开显示「可能已失效」）——'
                  '那一页有「自动检测规则」，会按当前页面重新试算选择器，'
                  '先给你预览，确认后才写回。\n'
                  // 一键导入
                  '网页上那种「一键导入」链接（yuedu:// …）也能用：'
                  '在内置浏览器里点了会弹确认，或者由系统把我们拉起来。'
                  '书源和订阅源会分开弹各自的勾选窗。',
            ),
            _step(
              Icons.cloud_outlined,
              '本地书架 / 在线书架',
              '文档库搜索栏下面有两个分类：本地书架（导入或下载下来的文件）'
                  '和在线书架（只记书源里的书，正文按需抓）。\n'
                  '在线阅读不等于加入书架 —— 只有点了「放入书架」才会进去。\n'
                  '在线书架每行有下载键；已经整本下好的会标「已下载」，'
                  '点开直接读本地那份，不再联网。\n'
                  '把本地下载的文件删掉时，书架里那本不会被移出，之后点开回到在线阅读。',
            ),
            _step(
              Icons.add_circle_outline,
              '导入文档',
              '文档库搜索栏右边的方形「+」导入 PDF / EPUB / TXT；也可以用别的应用「分享 → 桃花源阅读器」直接读一段文字。',
            ),
            _step(
              Icons.play_circle_outline,
              '开始朗读',
              // 与原版 1.20.0 的实际行为一致：PDF 与文本都是**点击即读**
              '点一下句子就开始读（PDF 点页面上的文字，TXT / EPUB 点句子），'
                  '之后点其他句子直接切换。',
            ),
            _step(
              Icons.tune,
              '朗读控制',
              '底部控制中心：暂停 / 上一句 / 下一句，点开还能调语速音调、切换自动排版与目录。\n'
                  // §4.92 + §4.101：方块键有**两种**语义，按「在哪儿按」区分。
                  // 教程原来只写「方块键结束朗读」，用户按了会发现跟说的不一样。
                  '方块键在文档库里按：结束朗读，控制栏整条消失；\n'
                  '在阅读页里按：只收起成小圆盘，会话保留，点播放就接着读。',
            ),
            _step(
              Icons.tab,
              '浏览器标签页',
              // v1.21.39 新增：图标在地址栏那一行的首页键右边
              '地址栏那一行「首页」右边是标签页按钮（角标显示开了几个）。'
                  '点开可以新建、切换、关闭标签，切走再切回不会丢滚动位置（页面保持活着）。\n'
                  '最多 8 个标签 —— 每个标签都占内存，到上限就关掉几个再开。',
            ),
            _step(
              Icons.auto_stories_outlined,
              '朗读中的新能力',
              '开始朗读后会一句接一句自动连读，读完一页自动翻页，不用一直点。\n'
                  '退出阅读页回文档库，朗读继续；用文档库底部的控制栏也能遥控播放、切换句子。\n'
                  '朗读位置会自动记住：下次进来、或中途结束后再读，都从上次那句接着读。\n'
                  // §4.100 任务 E：换文档 = 音乐播放器换歌
                  '打开另一本书开始朗读时，上一本会自动停下并记住位置（就像音乐播放器换歌）。\n'
                  '朗读时用目录跳章节：先暂停，跳到那一页后点播放键接着读。',
            ),
            _step(
              Icons.translate,
              '网页翻译与下载',
              // v1.21.36：翻译选路改成「谷歌优先、百度兜底」，界面上要提前说明，
              // 否则用户会以为"翻译出来的页面怎么跟平时不是一家"。
              '网页菜单里的「翻译本页」会优先用谷歌整页翻译；谷歌连不上时自动改用百度，'
                  '并会提示一句。翻译后的界面长得不一样是正常的——那一页由翻译服务方生成。\n'
                  // 下载：走系统下载管理器，落点是"系统下载目录"或用户设的目录
                  // v1.21.39：保存位置改成"完整路径 + 🔄 恢复默认 + 📂 选文件夹"，
                  // 教程必须跟着说清新入口，否则用户找不到在哪改。
                  '网页里的文件点下载会交给系统下载管理器，可在菜单「下载列表」里看进度。\n'
                  // v1.21.39：下载保持服务端原名（重定向站点会自己再问一次）
                  '下载下来的文件名跟网页上给的一样（原来遇到中转链接会变成 redirection.pdf）。\n'
                  // v1.21.39：下载列表每项右侧按状态是"叉"或"垃圾桶"
                  '列表里正在下的显示叉（取消下载），已下完的显示垃圾桶（只从列表移除，'
                  '不会删掉文件 —— 文件可能已经进了文档库）。\n'
                  '保存位置在设置里：那一行直接显示完整路径，'
                  '右边的 🔄 恢复成系统「下载」目录，📂 选自定义文件夹'
                  '（自定义只在应用自己的目录里生效——系统「下载」目录不允许我们建子文件夹）。\n'
                  // v1.21.41：下载列表标题行的文件夹图标改成"直接跳过去"
                  '下载列表标题栏那个文件夹图标会直接跳到下载文件夹'
                  '（少数机型没有能打开的文件夹管理器，那就显示路径让你复制）。\n'
                  // v1.21.41：设置页新增"存到外部存储"
                  '想把书放在应用自己的目录里（文件管理器也看得到），'
                  '设置里点「存到外部存储」即可。\n'
                  // v1.21.41：后台下载
                  '发起下载后可以退到桌面甚至关掉应用——下载完成后再打开应用，'
                  '书会自动出现在文档库里。',
            ),
            _step(
              Icons.headphones_outlined,
              '耳机与打断',
              '耳机播放键暂停或继续，上一首 / 下一首切句或切章（可在设置里选）。'
                  '其它应用出声或来电话时可自动暂停，结束后接着读。',
            ),
            _step(
              Icons.settings_outlined,
              '更多设置',
              '设置里可以调阅读底色与字号、屏幕常亮、下载目录、复制即朗读等。',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        dontShow,
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey<String>('tutorial-start'),
            onPressed: () => Navigator.of(context).pop(_dontShowAgain),
            child: const Text('开始使用'),
          ),
        ),
      ],
    );
  }

  /// 一条教程：图标 + 标题 + 说明
  Widget _step(IconData icon, String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 10),
            child: Icon(icon, size: 20, color: scheme.primary),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
