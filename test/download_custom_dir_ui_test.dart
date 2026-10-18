import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_reader/pages/settings_page.dart';
import 'package:tts_reader/services/storage_service.dart';
import 'package:tts_reader/tts/tts_manager.dart';

/// **设置页「选文件夹」这条路**（v1.21.44：自定义文件夹真正能用）
///
/// ## 为什么这一版要重测这条
///
/// v1.21.40 的结论是"自定义文件夹只有部分机型可用"，原因是**判据太窄**：
/// 只接受落在应用私有基准目录之内的路径（`StorageService.isUnderAnyBase`），
/// 而系统文件选择器**进不去**应用私有目录 —— 于是这个功能实际上永远选不成。
///
/// 这一版把判据放开成"是文件系统路径就收，能不能写**当场实测**"：
/// * `content://`（云盘 / 快捷方式）→ 仍然拒；
/// * 普通路径 → `StorageService.isWritableDir()` 真写一个 2 字节探针；
/// * 写不进 → 弹窗说清"系统不允许写这个位置"，**不保存**（不能留半态）。
///
/// 这里用假的 `FilePicker.platform` 把这四种结果都走一遍 ——
/// 真机上"选云盘""选一个没权限的目录"都很难复现，只有 mock 能稳定钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDocs;
  late Directory tmpRoot;

  /// path_provider 的平台通道（`writableBaseDirs` 会依次问这三个）
  const MethodChannel pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tutorial_done': true,
      'tutorial_content_version': 99,
    });
    StorageService.instance.resetForTest();
    await StorageService.instance.init();

    appDocs = Directory.systemTemp.createTempSync('tts_custom_appdocs_');
    tmpRoot = Directory.systemTemp.createTempSync('tts_custom_pick_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return appDocs.path;
        case 'getApplicationSupportDirectory':
          return appDocs.path;
        case 'getExternalStorageDirectory':
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    for (final Directory d in <Directory>[appDocs, tmpRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  /// 造一个**落在应用可写基准目录之内**的路径
  ///
  /// ⚠️ 为什么不用 `Directory.systemTemp`：widget 测试的 FakeAsync 时区里，
  /// 真实文件 IO（建目录 / 写探针）的 Future **永远不完成**，
  /// 走"实测可写"那条分支会把整条 await 链卡死（用例表现为"什么都没发生"）。
  /// 而"落在基准目录内 → 直接通过"是**纯字符串前缀比对**，不碰磁盘，稳定可测。
  Future<String> pickPathUnderAppBase(WidgetTester tester, String leaf) async {
    final List<String> bases = await tester.runAsync(
          () => StorageService.writableBaseDirs(),
        ) ??
        <String>[];
    expect(bases, isNotEmpty,
        reason: '宿主上至少要有应用文档目录，否则这条用例的前提不成立');
    expect(await StorageService.isUsableCustomDir('${bases.first}/$leaf'), isTrue);
    return '${bases.first}/$leaf';
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    // ⚠️ 设置页很长，"保存位置"卡在很下面：ListView 是懒构建的，
    // 用默认 800×600 的测试视口**根本不会建出那张卡**（find.byKey 找不到，
    // 一按就 "could not find any matching widgets"）。把测试视口调高，
    // 一次把整页建出来，避免在用例里写脆弱的滚动逻辑。
    tester.view.physicalSize = const Size(1200, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<TtsManager>.value(
        value: TtsManager.instance,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapPick(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('download-path-pick')));
    await tester.pump(); // 让点击处理器启动
    await tester.pump(); // 让 setState / 对话框上屏
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('① 选到一个可写目录 → 保存路径 + 来源标记变「自定义文件夹」', (tester) async {
    // ⚠️ 这里**必须**选"落在应用可写基准目录之内"的路径，原因见文件末尾的长注释：
    // widget 测试跑在 FakeAsync 时区里，`dart:io` 的真实异步 IO（建目录 / 写探针）
    // **永远不会完成** —— 走探针那条路会把整条 async 链卡住，用例只会看到"什么都没发生"。
    // 而"落在基准目录内 → 直接通过（纯字符串比对，不探测）"这条分支在这里可测。
    final String picked = await pickPathUnderAppBase(tester, 'MyBooks');
    FilePicker.platform = _FakeFilePicker(picked);

    await pumpSettings(tester);
    await tapPick(tester);

    final StorageService storage = StorageService.instance;
    expect(storage.customDownloadPath, picked,
        reason: '选中的路径必须存下来（这是"自选文件夹"的核心）');
    expect(storage.downloadTarget, DownloadTarget.custom,
        reason: '来源标记要跟着变，设置页才显示得对');
    expect(storage.downloadPath, picked);
    expect(find.textContaining('保存位置（自定义文件夹）'), findsOneWidget,
        reason: '卡片标题要显示"当前来源"');
    expect(find.textContaining(picked), findsWidgets,
        reason: '卡片副标题要显示自选路径');
  });

  testWidgets('② 用户取消 → 什么都不变（不留"选了自定义但没有目录"的半态）', (tester) async {
    FilePicker.platform = _FakeFilePicker(null);

    await pumpSettings(tester);
    await tapPick(tester);

    final StorageService storage = StorageService.instance;
    expect(storage.hasCustomDownloadPath, isFalse);
    expect(storage.customDownloadPath, isEmpty);
    expect(storage.downloadTarget, DownloadTarget.publicDownloads,
        reason: '★取消不该改动保存位置（尤其不能悄悄改成应用私有目录）');
    expect(find.textContaining('保存位置（系统下载目录）'), findsOneWidget);
  });

  testWidgets('③ 选到 content:// （系统文件选择器给出的特殊地址）→ 拒掉，不保存', (tester) async {
    const String cloudUri =
        'content://com.android.externalstorage.documents/tree/primary%3ADrive';
    FilePicker.platform = _FakeFilePicker(cloudUri);

    await pumpSettings(tester);
    await tapPick(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(StorageService.instance.hasCustomDownloadPath, isFalse,
        reason: 'flutter_downloader 只吃文件系统路径，SAF 的 URI 存了也没用');
    expect(find.text('这个位置用不了'), findsOneWidget,
        reason: '必须当场说清楚，不能静默失败');
    expect(find.textContaining('系统文件选择器返回了特殊地址'), findsOneWidget);
    expect(find.textContaining('云盘'), findsNothing,
        reason: '★用户明确要求：文案里不许出现"云盘"字样');
  });

  testWidgets('④ 选到「存储根」→ 拒掉（请先进入具体文件夹），不保存', (tester) async {
    // 说明：真正的"写不进去"（探针失败 → "系统不允许写这个位置"）**没法在 widget 测试里复现**
    // （真实 IO 在 FakeAsync 里不完成，见文件末尾注释）—— 那条判据由
    // `test/browser_download_test.dart` 里的 `isUsableCustomDir` 用例守着
    // （临时目录能写 / content:// 不能写 / 父级是文件的路径不能写）。
    // 这里守的是"被拒之后**什么都不保存**"这条 UI 行为。
    FilePicker.platform = _FakeFilePicker('/storage/emulated/0');

    await pumpSettings(tester);
    await tapPick(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(StorageService.instance.hasCustomDownloadPath, isFalse,
        reason: '被拒的路径绝不能存下来');
    expect(StorageService.instance.downloadTarget, DownloadTarget.publicDownloads);
  });

  testWidgets('⑤ 恢复默认 → 清掉自选路径，来源标记回到「系统下载目录」', (tester) async {
    final String picked = await pickPathUnderAppBase(tester, 'Books');
    FilePicker.platform = _FakeFilePicker(picked);

    await pumpSettings(tester);
    await tapPick(tester);
    expect(StorageService.instance.hasCustomDownloadPath, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('download-path-reset')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(StorageService.instance.hasCustomDownloadPath, isFalse);
    expect(StorageService.instance.downloadTarget, DownloadTarget.publicDownloads,
        reason: '不能留下"标记说自定义、路径却已清掉"的半态');
    expect(find.textContaining('保存位置（系统下载目录）'), findsOneWidget);
  });
  testWidgets('⑥ 没有「所有文件访问」权限 → 先弹说明，点取消则什么都不变', (tester) async {
    // 桌面测试环境拿不到真实 Android 权限 —— 用测试开关强制成"未授权"
    StorageService.debugAllFilesAccessOverride = false;
    addTearDown(() => StorageService.debugAllFilesAccessOverride = null);
    FilePicker.platform = _FakeFilePicker(null); // 万一真拉到选择器，返回"取消"

    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey<String>('download-path-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('需要「所有文件访问」权限'), findsOneWidget,
        reason: '★没权限时不能直接拉选择器（用户选完也是白选）');

    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(StorageService.instance.hasCustomDownloadPath, isFalse);
    expect(StorageService.instance.downloadTarget, DownloadTarget.publicDownloads,
        reason: '取消不该改动保存位置');
  });

  testWidgets('⑦ 没权限 → 点「去授权」但用户没开 → 明确提示，且不保存', (tester) async {
    StorageService.debugAllFilesAccessOverride = false; // 授权后仍"没开"
    addTearDown(() => StorageService.debugAllFilesAccessOverride = null);
    FilePicker.platform = _FakeFilePicker(null);

    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey<String>('download-path-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('去授权'));
    await tester.pump(); // 跳转（测试里是空实现）
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('未获得权限，无法自选文件夹'), findsOneWidget,
        reason: '★从设置页回来必须**重新查**，不能假设用户一定开了');
    expect(StorageService.instance.hasCustomDownloadPath, isFalse);
  });

  testWidgets('⑧ 已授权时不再弹权限说明（直接进选择器流程）', (tester) async {
    StorageService.debugAllFilesAccessOverride = true;
    addTearDown(() => StorageService.debugAllFilesAccessOverride = null);
    FilePicker.platform = _FakeFilePicker(null); // 取消

    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey<String>('download-path-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('需要「所有文件访问」权限'), findsNothing);
  });
}

/// 只替掉 `getDirectoryPath`：模拟用户在选择器里选了什么（null = 取消）
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final String? result;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async =>
      result;
}