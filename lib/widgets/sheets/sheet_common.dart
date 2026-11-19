import 'package:flutter/material.dart';

import '../../data/app_nav.dart';
import '../../data/app_settings.dart';
import '../../data/models.dart';
import '../format.dart';
import '../timed_snack.dart';
import '../../util/date_text.dart';

// 追加・変更シートの共通部品（2026-11-19 の整理で add_sheets.dart から分けた）

String sheetDateLabel(DateTime d) => '${d.year}/${d.month}/${d.day}（${weekdayJa(d)}）';

/// 件名から「Re:」などを取り除いて、予定やタスクの名前の初期値にする
String cleanMailSubject(String s) =>
    s.replaceAll(RegExp(r'^\s*((re|fw|fwd)\s*:\s*)+', caseSensitive: false), '').trim();

String mailSourceNote(Mail mail) =>
    'メール：${mail.subject}\n${mail.senderName}・${formatFull(mail.receivedAt)}';

/// AIが作ったメモ欄の内容があれば、その下に元メールの情報を付ける
String noteWithMail(String? aiNote, Mail mail) {
  final n = aiNote?.trim() ?? '';
  return n.isEmpty ? mailSourceNote(mail) : '$n\n\n${mailSourceNote(mail)}';
}

/// メモ欄の内容と、元の予定などの情報をつなげる
String joinSourceNote(String? note, String? source) {
  final n = note?.trim() ?? '';
  final src = source?.trim() ?? '';
  if (src.isEmpty) return n;
  return n.isEmpty ? src : '$n\n\n$src';
}

/// 保存後に「開く」付きのお知らせを出す（設定でオフにできる）
void showSavedSnack(BuildContext context, String message, int tab) {
  if (!appSettings.showSavedNotice) return;
  if (tabIndex.value == tab) {
    showTimedSnack(context, message);
  } else {
    showTimedSnack(context, message, actionLabel: '開く', onAction: () => tabIndex.value = tab);
  }
}

Future<T?> showFormSheet<T>(BuildContext context, Widget child) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: child,
      ),
    ),
  );
}

/// フォームのAIボタンに渡すメールの情報
String mailForAi(Mail mail) =>
    'メール\n差出人：${mail.senderName} <${mail.senderAddress}>\n件名：${mail.subject}\n本文：\n${mail.body}';
