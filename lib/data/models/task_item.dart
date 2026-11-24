import 'package:googleapis/tasks/v1.dart' as gtasks;

import 'link_refs.dart';
import 'memo.dart';

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
    this.colorKey,
    this.eventLinks = const [],
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

  /// つないだ予定（メモ欄の最後の行に保存。note には入れない。2026-11-24 の25）
  final List<EventLinkRef> eventLinks;

  /// カードの色（MemoColor.key。null なら指定なし）。メモ欄の隠し行に保存する（2026-11-24 の24）
  final String? colorKey;

  MemoColor? get color => MemoColor.of(colorKey);

  /// 内容を変えた写しを作る（期限を消すときは clearDue: true）
  TaskItem copyWith({
    String? title,
    DateTime? due,
    bool clearDue = false,
    String? note,
    List<MemoLinkRef>? memoLinks,
    List<MailLinkRef>? mailLinks,
    String? colorKey,
    bool clearColor = false,
    List<EventLinkRef>? eventLinks,
  }) =>
      TaskItem(
        title: title ?? this.title,
        due: clearDue ? null : (due ?? this.due),
        note: note ?? this.note,
        done: done,
        googleTask: googleTask,
        memoLinks: memoLinks ?? this.memoLinks,
        mailLinks: mailLinks ?? this.mailLinks,
        colorKey: clearColor ? null : (colorKey ?? this.colorKey),
        eventLinks: eventLinks ?? this.eventLinks,
      );

  bool sameAs(TaskItem other) {
    if (identical(this, other)) return true;
    final a = googleTask?.id;
    return a != null && a == other.googleTask?.id;
  }
}
