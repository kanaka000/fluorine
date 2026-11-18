import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../data/app_settings.dart';
import '../data/calendar_store.dart';
import '../services/google_auth.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/calendar_ai.dart';
import '../widgets/header_actions.dart';
import '../widgets/sign_in_prompt.dart';
import '../widgets/swipe_delete.dart';
import '../widgets/sync_status.dart';
import 'event_detail_screen.dart';
import 'settings_screen.dart';

/// カレンダー（ログイン後はGoogleカレンダーの予定。期間は「カレンダーの設定」で変えられる）
/// 表示は2種類：スケジュールの一覧／月のカレンダー（上）＋選んだ日の予定（下）。右上のボタンで切り替える
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  static const _week = ['月', '火', '水', '木', '金', '土', '日'];

  bool _aiBusy = false;

  // ---------------- 表示の切り替え（一覧／月） ----------------

  /// 月のカレンダーで表示しているか（設定で「最後に使った表示」なら前回の表示から始める）
  bool _monthView = appSettings.calendarRememberView && appSettings.calendarMonthView;

  /// 月表示で見ている月の日と、選んでいる日
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateUtils.dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    if (_monthView) {
      WidgetsBinding.instance.addPostFrameCallback((_) => calendarStore.loadMonth(_focusedDay));
    }
  }

  void _toggleView() {
    setState(() => _monthView = !_monthView);
    appSettings.setCalendarMonthView(_monthView);
    if (_monthView) calendarStore.loadMonth(_focusedDay);
  }

  String _label(DateTime d, DateTime today) {
    final diff = d.difference(today).inDays;
    final base = '${d.month}/${d.day}（${_week[d.weekday - 1]}）';
    if (diff == 0) return '今日 $base';
    if (diff == 1) return '明日 $base';
    return base;
  }

  static String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // ---------------- AIボタン（予定の追加・予定についての質問） ----------------

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: calendarAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: calendarAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runCalendarAi(context, instruction, setBusy: (b) {
      if (mounted) setState(() => _aiBusy = b);
    });
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CalendarSettingsScreen()));
  }

  Widget _eventTile(CalendarEvent e, ThemeData theme) {
    final Widget time;
    if (e.allDay) {
      time = Text('終日', style: theme.textTheme.bodySmall);
    } else {
      time = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_hm(e.start), style: theme.textTheme.bodySmall),
          Text(DateUtils.isSameDay(e.start, e.end) ? _hm(e.end) : '〜${e.end.month}/${e.end.day}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ],
      );
    }
    final place = (e.location ?? '').trim();
    final note = (e.note ?? '').trim();
    final sub = [if (place.isNotEmpty) '📍 $place', if (note.isNotEmpty) note].join('\n');
    return ListTile(
      leading: SizedBox(width: 48, child: time),
      title: Text(e.title),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EventDetailScreen(event: e)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([calendarStore, googleAuth, appSettings]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('カレンダー'),
          actions: [
            // 表示の切り替え：一覧のときは📅（月へ）、月のときは≣（一覧へ）
            if (googleAuth.signedIn)
              IconButton(
                icon: Icon(_monthView ? Icons.view_agenda_outlined : Icons.calendar_month_outlined),
                tooltip: _monthView ? '一覧で表示' : '月のカレンダーで表示',
                onPressed: _toggleView,
              ),
            ...headerActions(
            // ログアウト中は✨を出さない
            onAi: googleAuth.signedIn ? _aiByVoice : null,
            onAiLongPress: _aiByText,
            aiBusy: _aiBusy,
            menuItems: [
              if (googleAuth.signedIn)
                HeaderMenuItem(
                  icon: Icons.refresh,
                  label: '再読み込み',
                  onTap: () => calendarStore.reload(prompt: true),
                ),
              HeaderMenuItem(
                icon: Icons.settings_outlined,
                label: 'カレンダーの設定',
                dividerBefore: true,
                onTap: _openSettings,
              ),
              HeaderMenuItem(
                icon: Icons.tune,
                label: '全体の設定',
                onTap: () => openGeneralSettings(context),
              ),
            ],
          ),
          ],
        ),
        // ログアウト中は＋を出さず、一覧の代わりにログインの案内
        floatingActionButton: !googleAuth.signedIn
            ? null
            : FloatingActionButton(
                tooltip: '予定を追加',
                // 月表示では、選んでいる日の予定として追加する
                onPressed: () => showAddEventSheet(context, null, date: _monthView ? _selectedDay : null),
                child: const Icon(Icons.add),
              ),
        body: googleAuth.signedIn
            ? (_monthView ? _monthBody(theme) : _body(theme))
            : const SignInPrompt(
                icon: Icons.calendar_month_outlined,
                message: 'Googleでログインすると、\nGoogleカレンダーの予定が表示されます',
              ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final today = DateUtils.dateOnly(DateTime.now());
    // 終わっていない予定（今日より前に始まって続いている予定は「今日」に出す）
    final events = calendarStore.events.where((e) => e.end.isAfter(today)).toList();
    final children = <Widget>[];
    DateTime? last;
    for (final e in events) {
      var day = DateUtils.dateOnly(e.start);
      if (day.isBefore(today)) day = today;
      if (day != last) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(_label(day, today),
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        ));
        last = day;
      }
      // 左右どちらかにスワイプすると削除（「元に戻す」で作り直す）
      children.add(SwipeToDelete(
        itemKey: ObjectKey(e),
        message: '予定を削除しました',
        onDelete: () => calendarStore.remove(e),
        onUndo: () => calendarStore.restore(e),
        child: _eventTile(e, theme),
      ));
    }
    if (children.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('予定はありません\n（下に引っ張ると読み込みます）', textAlign: TextAlign.center)),
      ));
    } else {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        child: Text(
          calendarStore.usingGoogle ? '今日から${appSettings.calendarDays}日分を表示しています' : '',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ));
    }
    return Column(
      children: [
        SyncStatus(
          loading: calendarStore.loading,
          error: calendarStore.error,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => calendarStore.reload(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- 月表示 ----------------

  Widget _monthBody(ThemeData theme) {
    final cs = theme.colorScheme;
    final today = DateUtils.dateOnly(DateTime.now());
    final dayEvents = calendarStore.eventsOn(_selectedDay);
    return Column(
      children: [
        SyncStatus(
          loading: calendarStore.loading || calendarStore.monthLoading,
          error: calendarStore.error,
        ),
        TableCalendar<CalendarEvent>(
          locale: 'ja',
          firstDay: DateTime(2000),
          lastDay: DateTime(2100, 12, 31),
          focusedDay: _focusedDay,
          currentDay: DateTime.now(),
          selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
          startingDayOfWeek:
              appSettings.weekStartsMonday ? StartingDayOfWeek.monday : StartingDayOfWeek.sunday,
          calendarFormat: CalendarFormat.month,
          availableCalendarFormats: const {CalendarFormat.month: '月'},
          availableGestures: AvailableGestures.horizontalSwipe,
          rowHeight: 46,
          daysOfWeekHeight: 22,
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: theme.textTheme.titleMedium ?? const TextStyle(fontSize: 17),
            leftChevronIcon: Icon(Icons.chevron_left, color: cs.onSurface),
            rightChevronIcon: Icon(Icons.chevron_right, color: cs.onSurface),
          ),
          daysOfWeekStyle: DaysOfWeekStyle(
            weekdayStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            weekendStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          calendarStyle: CalendarStyle(
            defaultTextStyle: TextStyle(color: cs.onSurface),
            weekendTextStyle: TextStyle(color: cs.onSurface),
            outsideTextStyle: TextStyle(color: cs.outline),
            todayDecoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
            todayTextStyle: TextStyle(color: cs.onPrimaryContainer, fontWeight: FontWeight.bold),
            selectedDecoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            selectedTextStyle: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.bold),
          ),
          eventLoader: calendarStore.eventsOn,
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) => _marker(events, cs),
          ),
          onDaySelected: (selected, focused) => setState(() {
            _selectedDay = DateUtils.dateOnly(selected);
            _focusedDay = focused;
          }),
          onPageChanged: (focused) {
            _focusedDay = focused;
            calendarStore.loadMonth(focused); // その月の予定を読み込む
          },
        ),
        const Divider(height: 1),
        // 下：選んだ日の予定
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => calendarStore.reload(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('${_label(_selectedDay, today)} の予定',
                      style: theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
                ),
                if (dayEvents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('予定はありません')),
                  ),
                for (final e in dayEvents)
                  // 左右どちらかにスワイプすると削除（「元に戻す」で作り直す）
                  SwipeToDelete(
                    itemKey: ObjectKey(e),
                    message: '予定を削除しました',
                    onDelete: () => calendarStore.remove(e),
                    onUndo: () => calendarStore.restore(e),
                    child: _eventTile(e, theme),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 予定のある日の印（設定：0＝点、1＝件数、2＝色付きの丸）
  Widget? _marker(List<CalendarEvent> events, ColorScheme cs) {
    if (events.isEmpty) return null;
    switch (appSettings.calendarMarker) {
      case 1:
        return Positioned(
          bottom: 1,
          child: Text('${events.length}',
              style: TextStyle(fontSize: 10, height: 1, color: cs.primary, fontWeight: FontWeight.bold)),
        );
      case 2:
        return Positioned.fill(
          child: IgnorePointer(
            child: Container(
              margin: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: cs.primary, width: 1.5),
              ),
            ),
          ),
        );
      default:
        return Positioned(
          bottom: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < (events.length > 3 ? 3 : events.length); i++)
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                ),
            ],
          ),
        );
    }
  }
}
