import 'package:flutter/material.dart';

import '../confirm_dialog.dart';
import '../../data/calendar_store.dart';
import '../../data/models.dart';
import '../../data/task_store.dart';
import '../../services/errors.dart';
import '../calendar_ai.dart';

// リンクのあるメールを削除するときの確認（2026-11-19 の整理で分けた）

/// このメールにリンクしている予定・タスクがあれば「削除してよいか」を確かめる。
/// リンクがなければ聞かずに true。予定は読み込み済みの分と Google カレンダーの検索で探す
Future<bool> confirmDeleteLinkedMail(BuildContext context, Mail mail) async {
  bool linked(List<MailLinkRef> l) => l.any((x) => x.id == mail.id);
  final events = <String, CalendarEvent>{};
  for (final e in calendarStore.allLoaded.where((e) => linked(e.mailLinks))) {
    events[e.id ?? '${events.length}'] = e;
  }
  try {
    final found = await calendarStore.searchMailLinked(mail.id).timeout(const Duration(seconds: 8));
    for (final e in found) {
      events.putIfAbsent(e.id ?? '${events.length}', () => e);
    }
  } catch (e) {
    devLog('削除前のリンクの検索に失敗: $e');
  }
  final tasks = taskStore.tasks.where((t) => linked(t.mailLinks)).toList();
  if (events.isEmpty && tasks.isEmpty) return true;
  if (!context.mounted) return false;
  final names = [
    for (final e in events.values) '・予定：${e.title}（${formatEventWhen(e)}）',
    for (final t in tasks) '・タスク：${t.title}',
  ];
  final ok = await askConfirm(context, title: 'リンクのあるメールです', message: 'このメールは次の予定・タスクにリンクしています。\n\n'
            '${names.join('\n')}\n\n'
            '削除しても、ゴミ箱にある間（約30日）はリンク先から開けます。そのあとは開けなくなります。'
            '削除しますか？', okLabel: '削除する', scrollable: true);
  return ok;
}
