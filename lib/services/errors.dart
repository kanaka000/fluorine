import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis/gmail/v1.dart' show DetailedApiRequestError;
import 'package:http/http.dart' as http;

/// 開発中（flutter run のデバッグ版）だけ、ターミナルに詳しい中身を出す（2026-11-18 セキュリティ対策 B05）。
/// リリース版（普段使い・配布用のビルド）では何も出さない
void devLog(String message) {
  if (kDebugMode) debugPrint(message);
}

/// アプリが自分で作った、そのまま画面に出してよい短いエラー文
class AppMessage implements Exception {
  const AppMessage(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 画面に出すエラー文を短い日本語にする。外部の応答（メール・アドレス・IDなどが入ることがある）はそのまま出さない。
/// 詳しい中身は開発中だけターミナルへ
String friendlyError(Object e) {
  devLog('エラーの詳細: $e');
  if (e is AppMessage) return e.message;
  if (e is TimeoutException) return '時間内に応答がありませんでした。電波の状態を確かめて、もう一度試してください';
  if (e is SocketException || e is HandshakeException || e is http.ClientException) {
    return 'ネットにつながっていないようです。電波の状態を確かめて、もう一度試してください';
  }
  if (e is DetailedApiRequestError) {
    final s = e.status ?? 0;
    if (s == 401 || s == 403) return 'Googleへのアクセスが許可されていません。ログインし直すと直ることがあります';
    if (s == 404) return '対象が見つかりませんでした（ほかの端末で削除された可能性があります）';
    if (s == 429) return 'Googleへの頼みごとが多すぎます。少し待ってからもう一度試してください';
    if (s >= 500) return 'Google側で一時的な問題が起きています。少し待ってからもう一度試してください';
    return 'Googleとのやり取りに失敗しました（$s）';
  }
  return '問題が起きました。もう一度試してください';
}
