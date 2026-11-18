import 'package:flutter/material.dart';

import '../data/app_settings.dart';

/// 最後に出したお知らせが消えたら完了する（まだ出ていなければ null）。
/// 「元に戻す」のお知らせが消えるのを待ってから画面を閉じたいときに使う（2026-11-17）
Future<void>? lastTimedSnackClosed;

/// ボタン付きのお知らせを出し、決まった秒数で必ず消す
void showTimedSnack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  int? seconds,
}) {
  showTimedSnackOn(ScaffoldMessenger.of(context), message,
      actionLabel: actionLabel, onAction: onAction, seconds: seconds);
}

/// [showTimedSnack] と同じ。画面の部品がもう消えているとき（スワイプで削除した行など）は、
/// 先に取っておいた ScaffoldMessenger を渡して使う
void showTimedSnackOn(
  ScaffoldMessengerState messenger,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  int? seconds,
}) {
  final secs = seconds ?? appSettings.noticeSeconds;
  messenger.clearSnackBars();
  final controller = messenger.showSnackBar(SnackBar(
    content: Text(message),
    duration: Duration(seconds: secs),
    action: (actionLabel != null && onAction != null)
        ? SnackBarAction(label: actionLabel, onPressed: onAction)
        : null,
  ));
  lastTimedSnackClosed = controller.closed.then((_) {});
  Future<void>.delayed(Duration(seconds: secs), () {
    try {
      controller.close();
    } catch (_) {}
  });
}
