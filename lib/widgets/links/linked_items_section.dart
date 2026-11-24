import 'package:material_ui/material_ui.dart';

import '../../data/calendar_store.dart';
import '../../data/link_lines.dart';
import '../../data/models.dart';
import '../../data/task_store.dart';
import '../../screens/event_detail_screen.dart';
import '../../screens/task_detail_screen.dart';
import '../../services/errors.dart';
import '../../services/google_auth.dart';
import '../calendar_ai.dart';
import '../task_ai.dart';
import '../timed_snack.dart';

// メモ・メールの詳細画面の「リンクしている予定・タスク」（2026-11-19 の整理で分けた）

bool _linksTo(List<MemoLinkRef> links, Memo memo) =>
    links.any((l) => (resolveMemoLink(l)?.id ?? l.id) == memo.id);

/// メモの詳細画面の「リンクしている予定・タスク」と「予定にリンク」「タスクにリンク」。
/// 出せるのは読み込み済みの予定（カレンダーの表示期間と、月表示で開いた月）・タスクだけ
class MemoBacklinkSection extends StatelessWidget {
  const MemoBacklinkSection({super.key, required this.memo});

  final Memo memo;

  @override
  Widget build(BuildContext context) {
    final ref = MemoLinkRef(memo.id, memoTitleOf(memo));
    return LinkedItemsSection(
      eventLinked: (e) => _linksTo(e.memoLinks, memo),
      taskLinked: (t) => _linksTo(t.memoLinks, memo),
      linkEvent: (e) => e.copyWith(memoLinks: [...e.memoLinks, ref]),
      linkTask: (t) => t.copyWith(memoLinks: [...t.memoLinks, ref]),
    );
  }
}

/// メールの詳細画面の「リンクしている予定・タスク」と「予定にリンク」「タスクにリンク」（2026-11-19）。
/// 予定は読み込み済みの分に加えて、Google カレンダーの検索でも探す（表示期間より先・過去も見つかる）
class MailBacklinkSection extends StatelessWidget {
  const MailBacklinkSection({super.key, required this.mailId, required this.subject});

  final String mailId;
  final String subject;

  @override
  Widget build(BuildContext context) {
    final ref = MailLinkRef(mailId, subject);
    bool linked(List<MailLinkRef> l) => l.any((x) => x.id == mailId);
    return LinkedItemsSection(
      eventLinked: (e) => linked(e.mailLinks),
      taskLinked: (t) => linked(t.mailLinks),
      linkEvent: (e) => e.copyWith(mailLinks: [...e.mailLinks, ref]),
      linkTask: (t) => t.copyWith(mailLinks: [...t.mailLinks, ref]),
      searchEvents: () => calendarStore.searchMailLinked(mailId),
    );
  }
}

/// 予定の詳細画面の「リンクしているタスク」と「タスクにリンク」（2026-11-24 の25）。
/// リンクはタスクの側にだけ保存するので、タスク（いつも全部読み込んでいる）から探す
class EventTaskBacklinkSection extends StatelessWidget {
  const EventTaskBacklinkSection({super.key, required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final id = event.id;
    if (id == null) return const SizedBox.shrink();
    return LinkedItemsSection(
      title: 'リンクしているタスク',
      showEvents: false,
      eventLinked: (_) => false,
      taskLinked: (t) => t.eventLinks.any((l) => l.id == id),
      linkEvent: (e) => e,
      linkTask: (t) => t.copyWith(eventLinks: [...t.eventLinks, EventLinkRef(id, event.title)]),
    );
  }
}

/// 「リンクしている予定・タスク」の共通部分
class LinkedItemsSection extends StatefulWidget {
  const LinkedItemsSection({
    super.key,
    required this.eventLinked,
    required this.taskLinked,
    required this.linkEvent,
    required this.linkTask,
    this.searchEvents,
    this.title = 'リンクしている予定・タスク',
    this.showEvents = true,
  });

  /// 見出し
  final String title;

  /// 予定を出すか（予定の詳細画面ではタスクだけ。2026-11-24 の25）
  final bool showEvents;

  final bool Function(CalendarEvent e) eventLinked;
  final bool Function(TaskItem t) taskLinked;

  /// リンクを足した予定・タスクを作る（保存はこの部品がする）
  final CalendarEvent Function(CalendarEvent e) linkEvent;
  final TaskItem Function(TaskItem t) linkTask;

  /// 読み込み済みの分のほかに、予定を探す方法（メールのリンク用）
  final Future<List<CalendarEvent>> Function()? searchEvents;

  @override
  State<LinkedItemsSection> createState() => _LinkedItemsSectionState();
}

class _LinkedItemsSectionState extends State<LinkedItemsSection> {
  bool _saving = false;
  bool _searching = false;

  /// 検索で見つかった予定（読み込み済みにないもの）
  List<CalendarEvent> _found = const [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    final search = widget.searchEvents;
    if (search == null || !googleAuth.signedIn) return;
    setState(() => _searching = true);
    try {
      final list = await search();
      if (mounted) setState(() => _found = list);
    } catch (e) {
      devLog('リンクしている予定の検索に失敗: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await job();
      if (mounted) showTimedSnack(context, done);
    } catch (e) {
      if (mounted) showTimedSnack(context, '保存できませんでした：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _linkEvent() async {
    final choices = calendarStore.events.where((e) => !widget.eventLinked(e)).toList();
    final e = await _pick<CalendarEvent>(
      title: 'リンクする予定を選ぶ',
      empty: calendarStore.events.isEmpty ? '表示期間の予定がありません' : 'リンクできる予定はもうありません',
      items: choices,
      label: (e) => e.title,
      sub: (e) => formatEventWhen(e),
      icon: Icons.event_outlined,
    );
    if (e == null || !mounted) return;
    await _run(() => calendarStore.update(e, widget.linkEvent(e)), '予定にリンクしました');
  }

  Future<void> _linkTask() async {
    final open = taskStore.tasks.where((t) => !t.done).toList();
    final choices = open.where((t) => !widget.taskLinked(t)).toList();
    final t = await _pick<TaskItem>(
      title: 'リンクするタスクを選ぶ',
      empty: open.isEmpty ? '未完了のタスクがありません' : 'リンクできるタスクはもうありません',
      items: choices,
      label: (t) => t.title,
      sub: (t) => t.due == null ? null : '期限：${formatDue(t.due!)}',
      icon: Icons.check_box_outlined,
    );
    if (t == null || !mounted) return;
    await _run(() => taskStore.update(t, widget.linkTask(t)), 'タスクにリンクしました');
  }

  Future<T?> _pick<T>({
    required String title,
    required String empty,
    required List<T> items,
    required String Function(T) label,
    required String? Function(T) sub,
    required IconData icon,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) {
        final theme = Theme.of(c);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(empty, style: TextStyle(color: theme.colorScheme.outline)),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final x in items)
                          ListTile(
                            leading: Icon(icon),
                            title: Text(label(x), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: sub(x) == null ? null : Text(sub(x)!),
                            onTap: () => Navigator.pop(c, x),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([calendarStore, taskStore, googleAuth]),
      builder: (context, _) {
        // 読み込み済みの予定を先に（変更が反映済み）、検索で見つかった分は重ならないものだけ足す
        final loaded = calendarStore.allLoaded;
        final ids = {for (final e in loaded) if (e.id != null) e.id!};
        final events = !widget.showEvents ? <CalendarEvent>[] : [
          ...loaded.where(widget.eventLinked),
          ..._found.where((e) => e.id == null || !ids.contains(e.id)).where(widget.eventLinked),
        ]..sort((a, b) => a.start.compareTo(b.start));
        final tasks = taskStore.tasks.where(widget.taskLinked).toList();
        final signedIn = googleAuth.signedIn;
        if (!signedIn && events.isEmpty && tasks.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 24),
            Row(
              children: [
                Text(widget.title, style: theme.textTheme.titleSmall),
                if (_searching) ...[
                  const SizedBox(width: 8),
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            ),
            if (events.isEmpty && tasks.isEmpty && !_searching)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('まだありません',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ),
            for (final e in events)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(formatEventWhen(e)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => EventDetailScreen(event: e))),
              ),
            for (final t in tasks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(t.done ? Icons.check_box : Icons.check_box_outline_blank),
                title: Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.done
                        ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.outline)
                        : null),
                subtitle: t.due == null ? null : Text('期限：${formatDue(t.due!)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => TaskDetailScreen(task: t))),
              ),
            if (signedIn)
              Wrap(
                spacing: 8,
                children: [
                  if (widget.showEvents)
                    TextButton.icon(
                      icon: const Icon(Icons.event_outlined),
                      label: const Text('予定にリンク'),
                      onPressed: _saving ? null : _linkEvent,
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.check_box_outlined),
                    label: const Text('タスクにリンク'),
                    onPressed: _saving ? null : _linkTask,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

// ============ 予定・タスクの側：リンクしたメール（2026-11-19） ============
