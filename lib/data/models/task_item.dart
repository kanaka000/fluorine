import 'package:googleapis/tasks/v1.dart' as gtasks;

import 'link_refs.dart';

/// タスク1件
class TaskItem {
  TaskItem({
    required this.title,
    this.due,
    this.note,
    this.done = false,
    this.googleTask,
    this.memoLinks = const [],
    this.mailLinks = const [],
  });

  final String title;
  final DateTime? due;
  final String? note;
  bool done;

  /// Google ToDoリスト側のデータ（連携中のみ）
  final gtasks.Task? googleTask;

  /// つないだメモ（Googleのメモ欄の最後の行に保存。note には入れない）
  final List<MemoLinkRef> memoLinks;

  /// つないだメール（メモ欄の最後の行に保存。note には入れない。2026-11-19）
  final List<MailLinkRef> mailLinks;

  /// 内容を変えた写しを作る（期限を消すときは clearDue: true）
  TaskItem copyWith({
    String? title,
    DateTime? due,
    bool clearDue = false,
    String? note,
    List<MemoLinkRef>? memoLinks,
    List<MailLinkRef>? mailLinks,
  }) =>
      TaskItem(
        title: title ?? this.title,
        due: clearDue ? null : (due ?? this.due),
        note: note ?? this.note,
        done: done,
        googleTask: googleTask,
        memoLinks: memoLinks ?? this.memoLinks,
        mailLinks: mailLinks ?? this.mailLinks,
      );

  bool sameAs(TaskItem other) {
    if (identical(this, other)) return true;
    final a = googleTask?.id;
    return a != null && a == other.googleTask?.id;
  }
}
