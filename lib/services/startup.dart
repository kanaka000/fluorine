import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/app_settings.dart';
import '../data/calendar_store.dart';
import '../data/mail_store.dart';
import '../data/task_store.dart';
import 'google_auth.dart';
import 'sync.dart';
import 'errors.dart';
import 'attachment_opener.dart';

/// 起動時の準備（2026-11-16 追加）
/// メールの読み込みが終わるまでスプラッシュ画面を出し、終わったら startupDone を true にする

/// true になったらスプラッシュ画面からメールのトップ画面に切り替える
final startupDone = ValueNotifier<bool>(false);

/// スプラッシュ画面に出すバージョン（pubspec.yaml の version）
String appVersion = '';

/// メールの読み込みがこれより長くかかったら、待たずにメール画面へ進む
/// （読み込みはそのまま続き、メール画面の上部にプログレスバーが出る）
const _maxWait = Duration(seconds: 20);

/// バージョン番号を読み込む（runApp の前に呼ぶ）
Future<void> loadAppVersion() async {
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (e) {
    devLog('バージョンの取得エラー: $e');
  }
}

/// Googleログインの準備と、起動時のメールの読み込み
Future<void> runStartup() async {
  // 添付を開いたときの一時ファイルのうち、1日より古いものを消す（2026-11-19）
  unawaited(cleanupAttachmentCache());
  try {
    // 以前ログインしていれば、ログイン状態を復元する（電波が悪くて固まったときは待たずに進む）
    await googleAuth.init().timeout(_maxWait);
    // 未ログインのときは、すぐメール画面へ（ログインボタンのある画面）
    if (!googleAuth.signedIn) return;
    if (!appSettings.autoReloadOnStart) {
      // 「起動時に自動で読み込む」がオフ：読み込まずにメール画面へ（手動で再読み込み）
      clearAllForManual();
      return;
    }
    // メールが読み込み終わるまで待つ。カレンダー・タスクはメールのあとに裏で読み込む
    final mail = mailStore.reload();
    unawaited(mail
        .then((_) => Future.wait([calendarStore.reload(), taskStore.reload()]))
        .catchError((Object e) {
      devLog('起動時の読み込みエラー: $e');
      return <void>[];
    }));
    await mail.timeout(_maxWait, onTimeout: () {});
  } catch (e) {
    devLog('起動時の準備エラー: $e');
  } finally {
    startupDone.value = true;
  }
}
