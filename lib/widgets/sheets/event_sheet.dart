import 'package:material_ui/material_ui.dart';

import '../../data/app_nav.dart';
import '../../data/app_settings.dart';
import '../../data/calendar_store.dart';
import '../../data/models.dart';
import '../timed_snack.dart';
import '../../services/errors.dart';
import '../../util/date_text.dart';
import 'sheet_common.dart';
import '../../util/html_text.dart';

// 予定の追加・変更シート

/// 予定の追加。[mail] があればメールから作る（メモ欄に元メールの情報を付ける）。
/// [title] などを渡すと、その内容を入れた状態で開く（AIボタンから使う）。保存した予定を返す
Future<CalendarEvent?> showAddEventSheet(
  BuildContext context,
  Mail? mail, {
  String? title,
  DateTime? date,
  TimeOfDay? time,
  DateTime? endDate,
  TimeOfDay? endTime,
  bool? allDay,
  String? note,
  String? location,
}) async {
  final isAllDay = allDay ?? false;
  final start = _startOf(date ?? DateUtils.dateOnly(DateTime.now().add(const Duration(days: 1))),
      time, isAllDay);
  final draft = CalendarEvent(
    title: (title?.trim().isNotEmpty ?? false)
        ? title!.trim()
        : (mail == null ? '' : cleanMailSubject(mail.subject)),
    start: start,
    end: _endOf(start, isAllDay, endDate: endDate, endTime: endTime),
    allDay: isAllDay,
    note: mail == null ? (note?.trim() ?? '') : noteWithMail(note, mail),
    location: location?.trim() ?? '',
    // メールから作った予定には、元のメールをリンクする（2026-11-19）
    mailLinks: mail == null ? const [] : [MailLinkRef(mail.id, mail.subject)],
  );
  final saved = await showFormSheet<CalendarEvent>(context, _EventForm(draft: draft));
  if (saved != null && context.mounted) {
    showSavedSnack(context, '予定に追加しました', Tabs.calendar);
  }
  return saved;
}

/// 予定の変更。渡した項目だけを差し替えた状態で開く（AIボタンから使う）。変更後の予定を返す
Future<CalendarEvent?> showEditEventSheet(
  BuildContext context,
  CalendarEvent event, {
  String? title,
  DateTime? date,
  TimeOfDay? time,
  DateTime? endDate,
  TimeOfDay? endTime,
  bool? allDay,
  String? note,
  String? location,
}) async {
  final isAllDay = allDay ?? event.allDay;
  final keepTime = event.allDay ? null : TimeOfDay.fromDateTime(event.start);
  final start = _startOf(date ?? DateUtils.dateOnly(event.start), time ?? keepTime, isAllDay);
  DateTime end;
  if (endDate != null || endTime != null) {
    end = _endOf(start, isAllDay, endDate: endDate, endTime: endTime);
  } else if (isAllDay == event.allDay) {
    end = start.add(event.end.difference(event.start)); // 長さはそのまま
  } else {
    end = _endOf(start, isAllDay);
  }
  final draft = event.copyWith(
    title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : null,
    start: start,
    end: end,
    allDay: isAllDay,
    note: note,
    location: location,
  );
  final saved = await showFormSheet<CalendarEvent>(context, _EventForm(draft: draft, editing: event));
  if (saved != null && context.mounted && appSettings.showSavedNotice) {
    showTimedSnack(context, '予定を変更しました');
  }
  return saved;
}

/// 開始日時（時刻なし・終日なら、時刻ありのときは10:00）
DateTime _startOf(DateTime date, TimeOfDay? time, bool allDay) {
  if (allDay) return DateTime(date.year, date.month, date.day);
  final t = time ?? const TimeOfDay(hour: 10, minute: 0);
  return DateTime(date.year, date.month, date.day, t.hour, t.minute);
}

/// 終了日時。指定がなければ、終日は1日、時刻ありは設定の「標準の長さ」
DateTime _endOf(DateTime start, bool allDay, {DateTime? endDate, TimeOfDay? endTime}) {
  if (allDay) {
    final last = endDate ?? start;
    final end = DateTime(last.year, last.month, last.day + 1);
    return end.isAfter(start) ? end : DateTime(start.year, start.month, start.day + 1);
  }
  if (endTime != null) {
    final d = endDate ?? start;
    final end = DateTime(d.year, d.month, d.day, endTime.hour, endTime.minute);
    if (end.isAfter(start)) return end;
  }
  return start.add(Duration(minutes: appSettings.eventMinutes));
}

class _EventForm extends StatefulWidget {
  const _EventForm({required this.draft, this.editing});

  /// 入力欄の初期値
  final CalendarEvent draft;

  /// 変更するときの元の予定（追加なら null）
  final CalendarEvent? editing;

  @override
  State<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<_EventForm> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _location = TextEditingController(text: widget.draft.location ?? '');
  // 書式付き（HTML）のメモ欄（2026-11-22 の11）：欄には記号を外した文字を出し、
  // 直さずに保存したら元の HTML のまま、直したら書式のない文字で保存する
  late final String? _noteHtml =
      looksLikeHtml(widget.editing?.note ?? '') ? widget.editing!.note!.trim() : null;
  late final String? _noteHtmlText = _noteHtml == null ? null : eventNoteText(_noteHtml, keepLinks: true);
  late final _note = TextEditingController(
      text: looksLikeHtml(widget.draft.note ?? '')
          ? eventNoteText(widget.draft.note, keepLinks: true)
          : (widget.draft.note ?? ''));
  late bool _allDay = widget.draft.allDay;
  late DateTime _start = widget.draft.start;

  /// 時刻ありの終了日時、または終日の最後の日
  late DateTime _end = widget.draft.allDay ? widget.draft.lastDay : widget.draft.end;

  /// 終日をオフにしたときに使う時刻
  TimeOfDay _lastTime = const TimeOfDay(hour: 10, minute: 0);

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!_allDay) _lastTime = TimeOfDay.fromDateTime(_start);
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDate(DateTime initial) => showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );

  Future<TimeOfDay?> _pickTime(DateTime initial) =>
      showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));

  /// 開始を動かしたら、終了も同じだけ動かす（長さを保つ）
  void _moveStart(DateTime newStart) {
    final length = _end.difference(_start);
    setState(() {
      _start = newStart;
      _end = newStart.add(length);
    });
  }

  Future<void> _pickStartDate() async {
    final d = await _pickDate(_start);
    if (d == null) return;
    _moveStart(DateTime(d.year, d.month, d.day, _start.hour, _start.minute));
  }

  Future<void> _pickStartTime() async {
    final t = await _pickTime(_start);
    if (t == null) return;
    _moveStart(DateTime(_start.year, _start.month, _start.day, t.hour, t.minute));
  }

  Future<void> _pickEndDate() async {
    final d = await _pickDate(_end.isBefore(_start) ? _start : _end);
    if (d == null) return;
    setState(() => _end = DateTime(d.year, d.month, d.day, _end.hour, _end.minute));
  }

  Future<void> _pickEndTime() async {
    final t = await _pickTime(_end);
    if (t == null) return;
    setState(() => _end = DateTime(_end.year, _end.month, _end.day, t.hour, t.minute));
  }

  void _toggleAllDay(bool v) {
    setState(() {
      if (v) {
        _lastTime = TimeOfDay.fromDateTime(_start);
        _start = DateUtils.dateOnly(_start);
        _end = DateUtils.dateOnly(_end).isBefore(_start) ? _start : DateUtils.dateOnly(_end);
      } else {
        _start = DateTime(_start.year, _start.month, _start.day, _lastTime.hour, _lastTime.minute);
        _end = _start.add(Duration(minutes: appSettings.eventMinutes));
      }
      _allDay = v;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (_saving) return;
    if (title.isEmpty) {
      setState(() => _error = 'タイトルを入れてください');
      return;
    }
    final end = _allDay ? DateTime(_end.year, _end.month, _end.day + 1) : _end;
    if (!end.isAfter(_start)) {
      setState(() => _error = '終了は開始より後にしてください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final event = (widget.editing ?? widget.draft).copyWith(
      title: title,
      start: _start,
      end: end,
      allDay: _allDay,
      note: (_noteHtml != null && _note.text.trim() == _noteHtmlText!.trim()) ? _noteHtml : _note.text.trim(),
      location: _location.text.trim(),
    );
    try {
      final editing = widget.editing;
      final saved = editing == null
          ? await calendarStore.add(event)
          : await calendarStore.update(editing, event);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存できませんでした：${friendlyError(e)}';
        });
      }
    }
  }

  Widget _whenRow(String label, DateTime value, VoidCallback onDate, VoidCallback onTime) {
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label)),
        TextButton(onPressed: onDate, child: Text(sheetDateLabel(value))),
        if (!_allDay)
          TextButton(onPressed: onTime, child: Text('${pad2(value.hour)}:${pad2(value.minute)}')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(editing ? '📅 予定を変更' : '📅 予定に追加', style: Theme.of(context).textTheme.titleLarge),
        if (widget.editing?.recurring ?? false)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('繰り返しの予定です。この回だけが変わります。',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 16),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'タイトル')),
        const SizedBox(height: 8),
        TextField(
          controller: _location,
          decoration: const InputDecoration(labelText: '場所', prefixIcon: Icon(Icons.place_outlined)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('終日'),
          value: _allDay,
          onChanged: _toggleAllDay,
        ),
        _whenRow('開始', _start, _pickStartDate, _pickStartTime),
        _whenRow('終了', _end, _pickEndDate, _pickEndTime),
        const SizedBox(height: 8),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: 'メモ',
            helperText: _noteHtml == null ? null : 'パソコンで付けた書式があります。メモを直すと、書式のない文字で保存されます',
            helperMaxLines: 2,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

