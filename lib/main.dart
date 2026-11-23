import 'package:material_ui/material_ui.dart';

import 'data/app_settings.dart';
import 'data/memo_store.dart';
import 'data/sender_merges.dart';
import 'screens/home_shell.dart';
import 'screens/splash_screen.dart';
import 'services/ai/ai_usage.dart';
import 'services/ai/api_key_store.dart';
import 'services/google_auth.dart';
import 'services/notion_sync.dart';
import 'services/startup.dart';
import 'widgets/ja_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appSettings.load(); // 保存しておいた設定を読み込む
  await apiKeyStore.load(); // AnthropicのAPIキー（暗号化して保存。組み込まれたキーは1回だけ移す。2026-11-23）
  await aiUsage.load(); // AIの今月の使用額の目安・最後のエラー（2026-11-23）
  await senderMerges.load(); // 送信元のまとめ（アカウントごと。ログインしたアカウントの分を読み込む）
  googleAuth.addListener(() => senderMerges.setAccount(googleAuth.user?.email));
  await memoStore.load(); // 端末に保存したメモを読み込む
  await notionSync.load(); // Notion連携の状態（送れていないメモなど）
  MemoStore.onSaved = notionSync.memoSaved;
  MemoStore.onRemoved = notionSync.memoRemoved;
  await loadAppVersion(); // スプラッシュ画面に出すバージョン
  runApp(const FluorineApp());

  // Googleログインの準備と、起動時のメールの読み込み。
  // 終わるまではスプラッシュ画面を出す（未ログイン・自動読み込みオフのときはすぐ終わる）
  runStartup();

  // 前回Notionに送れなかったメモがあれば送り直す（連携がオンのときだけ）
  notionSync.flush();

  // 別のアプリから戻ってきたとき（バックグラウンドから復帰）は自動では読み込まない（2026-11-16 決定）
}

class FluorineApp extends StatelessWidget {
  const FluorineApp({super.key});

  static const _seed = Color(0xFF6D5B97);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => MaterialApp(
        title: 'Fluorine',
        debugShowCheckedModeBanner: false,
        themeMode: appSettings.themeMode,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed)),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        ),
        // 日付選択・時刻選択などを日本語で表示する
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja')],
        localizationsDelegates: jaLocalizationsDelegates,
        // まだ旧 material（package:flutter/material.dart）を使っているパッケージ（HTML表示・カレンダー・Markdown）にも、
        // テーマと日本語表示を渡す（2026-11-22 の18。material_ui への移行）
        // つなぎは移行のあいだだけの部品なので「非推奨」と出る。各パッケージが material_ui に移ったら外す
        // ignore: deprecated_member_use
        builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
        // 起動の準備が終わるまではスプラッシュ画面、終わったらメールのトップ画面
        home: ValueListenableBuilder<bool>(
          valueListenable: startupDone,
          builder: (context, done, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: done ? const HomeShell() : const SplashScreen(),
          ),
        ),
      ),
    );
  }
}
