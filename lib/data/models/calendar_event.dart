import 'link_refs.dart';
import 'memo.dart';

/// 予定1件
class CalendarEvent {
  CalendarEvent({
    this.id,
    required this.title,
    required this.start,
    DateTime? end,
    this.allDay = false,
    this.note,
    this.location,
    this.recurring = false,
    this.memoLinks = const [],
    this.mailLinks = const [],
    this.colorKey,
  }) : end = end ??
            (allDay
                ? DateTime(start.year, start.month, start.day + 1)
                : start.add(const Duration(hours: 1)));

  /// Googleカレンダーの予定ID（ダミーや未保存なら null）
  final String? id;
  final String title;
  final DateTime start;

  /// 終了日時。終日の予定は「最後の日の翌日」（Googleカレンダーと同じ表し方）
  final DateTime end;
  final bool allDay;
  final String? note;
  final String? location;

  /// 繰り返しの予定の1回分か
  final bool recurring;

  /// つないだメモ（Googleのメモ欄の最後の行に保存。note には入れない）
  final List<MemoLinkRef> memoLinks;

  /// つないだメール（メモ欄の最後の行に保存。note には入れない。2026-11-19）
  final List<MailLinkRef> mailLinks;

  /// カードの色（MemoColor.key。null なら指定なし）。メモ欄の隠し行に保存する（2026-11-24 の24）
  final String? colorKey;

  MemoColor? get color => MemoColor.of(colorKey);

  /// 終日の予定の最後の日
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? note,
    String? location,
    List<MemoLinkRef>? memoLinks,
    List<MailLinkRef>? mailLinks,
    String? colorKey,
    bool clearColor = false,
  }) =>
      CalendarEvent(
        id: id,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        note: note ?? this.note,
        location: location ?? this.location,
        recurring: recurring,
        memoLinks: memoLinks ?? this.memoLinks,
        mailLinks: mailLinks ?? this.mailLinks,
        colorKey: clearColor ? null : (colorKey ?? this.colorKey),
      );
}
