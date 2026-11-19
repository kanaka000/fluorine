import 'package:flutter/material.dart';

/// 「やめる」と実行ボタンの確認ダイアログ。実行を押したら true（2026-11-19 の整理で共通化）
Future<bool> askConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String okLabel,
  bool scrollable = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: scrollable ? SingleChildScrollView(child: Text(message)) : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(okLabel)),
      ],
    ),
  );
  return ok == true;
}
