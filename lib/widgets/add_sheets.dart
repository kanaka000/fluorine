import 'package:flutter/material.dart';

import '../data/app_nav.dart';
import '../data/app_settings.dart';
import '../data/calendar_store.dart';
import '../data/memo_store.dart';
import '../data/models.dart';
import '../data/task_store.dart';
import '../services/claude_service.dart';
import 'ai_prompt.dart';
import 'format.dart';
import 'header_actions.dart';
import 'memo_markdown.dart';
import 'timed_snack.dart';
import '../services/errors.dart';

const _week = ['月', '火', '水', '木', '金', '土', '日'];
String _dateLabel(DateTime d) => '${d.year}/${d.month}/${d.day}（${_week[d.weekday - 1]}）';
String _two(int v) => v.toString().padLeft(2, '0');

/// 件名から「Re:」などを取り除いて、予定やタスクの名前の初期値にする
String _cleanSubject(String s) =>
    s.replaceAll(RegExp(r'^\s*((re|fw|fwd)\s*:\s*)+', caseSensitive: false), '').trim();

String _sourceNote(Mail mail) =>
    'メール：${mail.subject}\n${mail.senderName}・${formatFull(mail.receivedAt)}';

/// AIが作ったメモ欄の内容があれば、その下に元メールの情報を付ける
String _noteWith(String? aiNote, Mail mail) {
  final n = aiNote?.trim() ?? '';
  return n.isEmpty ? _sourceNote(mail) : '$n\n\n${_sourceNote(mail)}';
}

/// メモ欄の内容と、元の予定などの情報をつなげる
String _joinNote(String? note, String? source) {
  final n = note?.trim() ?? '';
  final src = source?.trim() ?? '';
  if (src.isEmpty) return n;
  return n.isEmpty ? src : '$n\n\n$src';
}

/// 保存後に「開く」付きのお知らせを出す（設定でオフにできる）
void _savedSnack(BuildContext context, String message, int tab) {
  if (!appSettings.showSavedNotice) return;
  if (tabIndex.value == tab) {
    showTimedSnack(context, message);
  } else {
    showTimedSnack(context, message, actionLabel: '開く', onAction: () => tabIndex.value = tab);
  }
}

Future<T?> _sheet<T>(BuildContext context, Widget child) {
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

// ---------------- 予定 ----------------

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
        : (mail == null ? '' : _cleanSubject(mail.subject)),
    start: start,
    end: _endOf(start, isAllDay, endDate: endDate, endTime: endTime),
    allDay: isAllDay,
    note: mail == null ? (note?.trim() ?? '') : _noteWith(note, mail),
    location: location?.trim() ?? '',
  );
  final saved = await _sheet<CalendarEvent>(context, _EventForm(draft: draft));
  if (saved != null && context.mounted) {
    _savedSnack(context, '予定に追加しました', Tabs.calendar);
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
  final saved = await _sheet<CalendarEvent>(context, _EventForm(draft: draft, editing: event));
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
  late final _note = TextEditingController(text: widget.draft.note ?? '');
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
      note: _note.text.trim(),
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
        TextButton(onPressed: onDate, child: Text(_dateLabel(value))),
        if (!_allDay)
          TextButton(onPressed: onTime, child: Text('${_two(value.hour)}:${_two(value.minute)}')),
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
          decoration: const InputDecoration(labelText: 'メモ'),
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

// ---------------- タスク ----------------

/// タスクの追加。[mail] があればメールから作る。[source] は元の予定などの情報（メモ欄に付ける）。
/// 保存したタスクを返す
Future<TaskItem?> showAddTaskSheet(
  BuildContext context,
  Mail? mail, {
  String? title,
  DateTime? due,
  String? note,
  String? source,
}) async {
  final initialTitle = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : (mail == null ? '' : _cleanSubject(mail.subject));
  final initialNote = mail == null ? _joinNote(note, source) : _noteWith(note, mail);
  final saved = await _sheet<TaskItem>(
    context,
    _TaskForm(
      draft: TaskItem(title: initialTitle, due: due, note: initialNote),
      aiSource: mail == null ? source : _mailForAi(mail),
    ),
  );
  if (saved != null && context.mounted) {
    _savedSnack(context, 'タスクに追加しました', Tabs.task);
  }
  return saved;
}

/// タスクの変更。渡した項目だけを差し替えた状態で開く（AIボタンから使う）。変更後のタスクを返す
Future<TaskItem?> showEditTaskSheet(
  BuildContext context,
  TaskItem task, {
  String? title,
  DateTime? due,
  bool clearDue = false,
  String? note,
}) async {
  final draft = task.copyWith(
    title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : null,
    due: due,
    clearDue: clearDue,
    note: note,
  );
  final saved = await _sheet<TaskItem>(context, _TaskForm(draft: draft, editing: task));
  if (saved != null && context.mounted && appSettings.showSavedNotice) {
    showTimedSnack(context, 'タスクを変更しました');
  }
  return saved;
}

/// フォームのAIボタンに渡すメールの情報
String _mailForAi(Mail mail) =>
    'メール\n差出人：${mail.senderName} <${mail.senderAddress}>\n件名：${mail.subject}\n本文：\n${mail.body}';

class _TaskForm extends StatefulWidget {
  const _TaskForm({required this.draft, this.editing, this.aiSource});

  /// 入力欄の初期値
  final TaskItem draft;

  /// 変更するときの元のタスク（追加なら null）
  final TaskItem? editing;

  /// フォームのAIボタンに渡す元の情報（メール本文など）
  final String? aiSource;

  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _note = TextEditingController(text: widget.draft.note ?? '');
  late DateTime? _due = widget.draft.due;

  bool _saving = false;
  bool _aiBusy = false;
  String? _error;

  /// AIが入れる前の入力欄（「元に戻す」用）
  ({String title, DateTime? due, String note})? _beforeAi;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? DateUtils.dateOnly(DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _due = d);
  }

  // ---------------- AIボタン（入力欄を埋める） ----------------

  static const _aiHint = '例：期限は来週の金曜／見積書を送る、メモに金額を入れて／名前を短くして';

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _runAi(String instruction) async {
    if (_aiBusy) return;
    setState(() {
      _aiBusy = true;
      _error = null;
    });
    try {
      final r = await ClaudeService.fillTask(
        instruction: instruction,
        title: _title.text,
        due: _due,
        note: _note.text,
        source: widget.aiSource,
      );
      if (!mounted) return;
      setState(() {
        _beforeAi = (title: _title.text, due: _due, note: _note.text);
        if (r.title.isNotEmpty) _title.text = r.title;
        _due = r.due;
        _note.text = r.note;
        _aiBusy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _aiBusy = false;
          _error = 'AIに頼めませんでした：${friendlyError(e)}';
        });
      }
    }
  }

  void _undoAi() {
    final b = _beforeAi;
    if (b == null) return;
    setState(() {
      _title.text = b.title;
      _due = b.due;
      _note.text = b.note;
      _beforeAi = null;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (_saving) return;
    if (title.isEmpty) {
      setState(() => _error = 'やることを入れてください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final base = widget.editing ?? widget.draft;
    final task = base.copyWith(title: title, due: _due, clearDue: _due == null, note: _note.text.trim());
    try {
      final editing = widget.editing;
      final saved =
          editing == null ? await taskStore.add(task) : await taskStore.update(editing, task);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.editing != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(editing ? '✅ タスクを変更' : '✅ タスクに追加', style: theme.textTheme.titleLarge),
            ),
            AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
          ],
        ),
        Text('✨ タップで話して入力、長押しで文字で頼めます',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 12),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'やること')),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_outlined),
          title: Text(_due == null ? '期限なし' : '期限：${_dateLabel(_due!)}'),
          trailing: _due == null
              ? null
              : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _due = null)),
          onTap: _pickDue,
        ),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'メモ'),
        ),
        if (_beforeAi != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('AIが入れる前に戻す'),
              onPressed: _undoAi,
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: (_saving || _aiBusy) ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

// ---------------- メモ ----------------

/// メモの追加。[mail] があればメールから作る。[source] は元の予定・タスクなどの情報（本文の下に付ける）。
/// 保存したメモを返す
Future<Memo?> showAddMemoSheet(
  BuildContext context,
  Mail? mail, {
  String? title,
  String? body,
  String? source,
}) async {
  final initialTitle = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : (mail == null ? '' : _cleanSubject(mail.subject));
  final b = body?.trim() ?? '';
  final from = mail != null ? _sourceNote(mail) : (source?.trim() ?? '');
  final initialBody = from.isEmpty ? b : '$b\n\n---\n$from';
  final now = DateTime.now();
  final saved = await _sheet<Memo>(
    context,
    _MemoForm(
      draft: Memo(title: initialTitle, body: initialBody, createdAt: now),
      aiSource: mail == null ? source : _mailForAi(mail),
    ),
  );
  if (saved != null && context.mounted) {
    _savedSnack(context, 'メモに追加しました', Tabs.memo);
  }
  return saved;
}

/// メモの変更。渡した項目だけを差し替えた状態で開く（AIボタンから使う）。変更後のメモを返す
Future<Memo?> showEditMemoSheet(BuildContext context, Memo memo, {String? title, String? body}) async {
  final draft = Memo(
    id: memo.id,
    title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : memo.title,
    body: body ?? memo.body,
    createdAt: memo.createdAt,
    updatedAt: memo.updatedAt,
    colorKey: memo.colorKey,
  );
  final saved = await _sheet<Memo>(context, _MemoForm(draft: draft, editing: memo));
  if (saved != null && context.mounted && appSettings.showSavedNotice) {
    showTimedSnack(context, 'メモを変更しました');
  }
  return saved;
}

/// メモの色を選ぶ丸いボタンの列（左端は「指定なし」）
class MemoColorPicker extends StatelessWidget {
  const MemoColorPicker({super.key, required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget dot({required String? key, required Color? color, required String label}) {
      final isSel = selected == key;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: label,
          child: InkResponse(
            onTap: () => onChanged(key),
            radius: 22,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color ?? theme.colorScheme.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  width: isSel ? 3 : 1,
                ),
              ),
              child: color == null
                  ? Icon(Icons.format_color_reset_outlined, size: 18, color: theme.colorScheme.outline)
                  : (isSel ? const Icon(Icons.check, size: 18, color: Colors.black54) : null),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          dot(key: null, color: null, label: '指定なし'),
          for (final c in MemoColor.all)
            dot(key: c.key, color: c.cardColor(theme.brightness, theme.colorScheme.surface), label: c.label),
        ],
      ),
    );
  }
}

class _MemoForm extends StatefulWidget {
  const _MemoForm({required this.draft, this.editing, this.aiSource});

  /// 入力欄の初期値
  final Memo draft;

  /// 変更するときの元のメモ（追加なら null）
  final Memo? editing;

  /// フォームのAIボタンに渡す元の情報（メール本文など）
  final String? aiSource;

  @override
  State<_MemoForm> createState() => _MemoFormState();
}

class _MemoFormState extends State<_MemoForm> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _body = TextEditingController(text: widget.draft.body);
  final _bodyFocus = FocusNode();
  late String? _color = widget.draft.colorKey;

  bool _saving = false;
  bool _aiBusy = false;
  String? _error;

  /// AIが入れる前の入力欄（「元に戻す」用）
  ({String title, String body})? _beforeAi;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  // ---------------- AIボタン（入力欄を埋める） ----------------

  static const _aiHint = '例：要点を見出し付きで整理して／もっと短く／買うものをチェックリストにして／タイトルを付けて';

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _runAi(String instruction) async {
    if (_aiBusy) return;
    setState(() {
      _aiBusy = true;
      _error = null;
    });
    try {
      final r = await ClaudeService.fillMemo(
        instruction: instruction,
        title: _title.text,
        body: _body.text,
        source: widget.aiSource,
      );
      if (!mounted) return;
      setState(() {
        _beforeAi = (title: _title.text, body: _body.text);
        if (r.title.isNotEmpty) _title.text = r.title;
        if (r.body.isNotEmpty) _body.text = r.body;
        _aiBusy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _aiBusy = false;
          _error = 'AIに頼めませんでした：${friendlyError(e)}';
        });
      }
    }
  }

  void _undoAi() {
    final b = _beforeAi;
    if (b == null) return;
    setState(() {
      _title.text = b.title;
      _body.text = b.body;
      _beforeAi = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    var title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty && body.isEmpty) {
      setState(() => _error = 'タイトルか本文を入れてください');
      return;
    }
    // タイトルが空なら本文の1行目をタイトルにする
    if (title.isEmpty) {
      final first = body.split('\n').first.trim();
      title = first.length > 30 ? '${first.substring(0, 30)}…' : first;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final editing = widget.editing;
      final Memo saved;
      if (editing == null) {
        saved = await memoStore.add(Memo(
          title: title,
          body: body,
          createdAt: DateTime.now(),
          colorKey: _color,
        ));
      } else {
        saved = await memoStore.update(
          editing.copyWith(title: title, body: body, colorKey: _color, clearColor: _color == null),
        );
      }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.editing != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(editing ? '📝 メモを変更' : '📝 メモに追加', style: theme.textTheme.titleLarge),
            ),
            AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
          ],
        ),
        Text('✨ タップで話して入力、長押しで文字で頼めます',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 12),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'タイトル')),
        const SizedBox(height: 12),
        Text('色', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        MemoColorPicker(selected: _color, onChanged: (c) => setState(() => _color = c)),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          focusNode: _bodyFocus,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: '本文',
            alignLabelWithHint: true,
            helperText: 'Markdownで書けます（# 見出し、- 箇条書き、- [ ] チェック）',
          ),
        ),
        const SizedBox(height: 6),
        // カーソルのある行（選んだ行）の先頭に記号を入れる。もう一度押すと外す
        MarkdownToolbar(controller: _body, focusNode: _bodyFocus),
        if (_beforeAi != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('AIが入れる前に戻す'),
              onPressed: _undoAi,
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: (_saving || _aiBusy) ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
