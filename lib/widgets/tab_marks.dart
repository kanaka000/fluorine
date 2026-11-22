import 'package:material_ui/material_ui.dart';

import '../data/calendar_store.dart';
import '../data/task_store.dart';

/// 下のタブの印（2026-11-17）
/// - 今日：右上に赤い点（カレンダー＝まだ終わっていない今日の予定。タスク＝期限が今日まで〈期限切れを含む〉の未完了）
/// - 明日：右下に青い点（明日の予定・期限が明日の未完了タスク）
/// - 終日の予定も数える。両方あるときは赤と青の両方を出す
class DayMarks {
  const DayMarks({this.today = false, this.tomorrow = false});
  final bool today;
  final bool tomorrow;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// カレンダーの印
DayMarks calendarMarks([DateTime? at]) {
  final now = at ?? DateTime.now();
  final today = _day(now);
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  final dayAfter = DateTime(today.year, today.month, today.day + 2);
  // 予定が [from, to) の時間にかかっているか（終日の予定の end は翌日0時）
  bool overlaps(CalendarEvent e, DateTime from, DateTime to) => e.start.isBefore(to) && e.end.isAfter(from);
  var t = false, n = false;
  for (final e in calendarStore.events) {
    if (!t && overlaps(e, today, tomorrow) && e.end.isAfter(now)) t = true; // 終わった予定は数えない
    if (!n && overlaps(e, tomorrow, dayAfter)) n = true;
    if (t && n) break;
  }
  return DayMarks(today: t, tomorrow: n);
}

/// タスクの印
DayMarks taskMarks([DateTime? at]) {
  final today = _day(at ?? DateTime.now());
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  var t = false, n = false;
  for (final task in taskStore.tasks) {
    final due = task.due;
    if (task.done || due == null) continue;
    final d = _day(due);
    if (!d.isAfter(today)) t = true; // 今日まで（期限切れも含む）
    if (d == tomorrow) n = true;
    if (t && n) break;
  }
  return DayMarks(today: t, tomorrow: n);
}

/// アイコンの右上に赤、右下に青の点を重ねる
class MarkedIcon extends StatelessWidget {
  const MarkedIcon({super.key, required this.icon, required this.marks});

  final IconData icon;
  final DayMarks marks;

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).colorScheme.surfaceContainer; // タブの背景に近い色で縁取り
    Widget dot(Color color) => Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 1.5),
          ),
        );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (marks.today) Positioned(right: -3, top: -3, child: dot(Colors.red)),
        if (marks.tomorrow) Positioned(right: -3, bottom: -3, child: dot(Colors.blue)),
      ],
    );
  }
}
