import 'package:material_ui/material_ui.dart';

import '../confirm_dialog.dart';
import '../../data/calendar_store.dart';
import '../../data/models.dart';
import '../../screens/event_detail_screen.dart';
import '../../services/errors.dart';
import '../../services/google_auth.dart';
import '../calendar_ai.dart';
import '../timed_snack.dart';

// タスクの詳細画面の「リンクした予定」と予定の選択（2026-11-24 の25）。
// リンクはタスクのメモ欄の隠し行 `📅 予定：タイトル〔event:ID〕` に保存する（予定の側には書かない）

/// タスクの詳細画面の「リンクした予定」（カードと「予定をリンク」ボタン）。
/// [onChanged] でリンクの一覧を保存する（Googleに送る。失敗したら例外）
class EventLinkSection extends StatefulWidget {
  const EventLinkSection({super.key, required this.links, required this.onChanged});

  final List<EventLinkRef> links;
  final Future<void> Function(List<EventLinkRef> links) onChanged;

  @override
  State<EventLinkSection> createState() => _EventLinkSectionState();
}

class _EventLinkSectionState extends State<EventLinkSection> {
  bool _saving = false;

  /// Google から読んだ予定（null＝消された・見つからない）。読み込み済みの予定はいつも calendarStore から出す
  final Map<String, CalendarEvent?> _fetched = {};
  final Set<String> _failed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EventLinkSection old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    for (final ref in widget.links) {
      final id = ref.id;
      if (calendarStore.loadedEvent(id) != null) continue;
      if (_fetched.containsKey(id) || _failed.contains(id)) continue;
      try {
        final e = await calendarStore.eventById(id);
        if (mounted) setState(() => _fetched[id] = e);
      } catch (e) {
        devLog('リンクした予定の読み込みに失敗: $e');
        if (mounted) setState(() => _failed.add(id));
      }
    }
  }

  Future<void> _save(List<EventLinkRef> links, String done) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(links);
      if (mounted) showTimedSnack(context, done);
    } catch (e) {
      if (mounted) showTimedSnack(context, '保存できませんでした：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _add() async {
    if (!googleAuth.signedIn) {
      showTimedSnack(context, '予定をリンクするには、Googleにログインしてください');
      return;
    }
    final e = await pickEvent(context, exclude: {for (final l in widget.links) l.id});
    if (e == null || e.id == null || !mounted) return;
    await _save([...widget.links, EventLinkRef(e.id!, e.title)], '予定をリンクしました');
  }

  Future<void> _unlink(EventLinkRef ref) async {
    final ok = await askConfirm(context,
        title: 'リンクを外しますか？', message: '「${ref.title}」へのリンクを外します。予定そのものは消えません。', okLabel: '外す');
    if (!ok || !mounted) return;
    await _save(widget.links.where((l) => !identical(l, ref)).toList(), 'リンクを外しました');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: calendarStore,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.links.isNotEmpty) ...[
            const Divider(height: 24),
            Text('リンクした予定', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final ref in widget.links) _card(ref, theme),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.event_outlined),
              label: const Text('予定をリンク'),
              onPressed: _saving ? null : _add,
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(EventLinkRef ref, ThemeData theme) {
    final scheme = theme.colorScheme;
    final e = calendarStore.loadedEvent(ref.id) ?? _fetched[ref.id];
    final loading = e == null && !_fetched.containsKey(ref.id) && !_failed.contains(ref.id);
    if (e == null && !loading) {
      // 消された予定、または読み込めなかった予定
      final gone = !_failed.contains(ref.id);
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        color: scheme.surfaceContainerHighest,
        child: ListTile(
          leading: Icon(gone ? Icons.link_off : Icons.cloud_off, color: scheme.outline),
          title: Text(gone ? '予定が見つかりません' : '予定を読み込めませんでした', style: TextStyle(color: scheme.outline)),
          subtitle: Text(ref.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(onPressed: _saving ? null : () => _unlink(ref), child: const Text('外す')),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: e?.color?.cardColor(theme.brightness, scheme.surface) ?? scheme.surfaceContainerHigh,
      child: ListTile(
        leading: const Icon(Icons.event_outlined),
        title: Text(e?.title ?? ref.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(e == null ? '読み込み中…' : formatEventWhen(e), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: e == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventDetailScreen(event: e))),
        onLongPress: _saving ? null : () => _unlink(ref),
      ),
    );
  }
}

/// 予定を1つ選ぶ（読み込み済みの予定のうち、今日から先のもの。文字で絞り込める）。[exclude] のIDは出さない
Future<CalendarEvent?> pickEvent(BuildContext context, {Set<String> exclude = const {}}) {
  return showModalBottomSheet<CalendarEvent>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _EventPicker(exclude: exclude),
  );
}

class _EventPicker extends StatefulWidget {
  const _EventPicker({required this.exclude});

  final Set<String> exclude;

  @override
  State<_EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends State<_EventPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _q.trim().toLowerCase();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final events = calendarStore.allLoaded
        .where((e) => e.id != null && !widget.exclude.contains(e.id))
        .where((e) => e.end.isAfter(today))
        .where((e) => q.isEmpty || e.title.toLowerCase().contains(q))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('リンクする予定を選ぶ', style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'タイトルで絞り込む',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
              if (events.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(q.isEmpty ? '今日から先の予定がありません' : '見つかりません',
                      style: TextStyle(color: theme.colorScheme.outline)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in events)
                        ListTile(
                          leading: const Icon(Icons.event_outlined),
                          title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(formatEventWhen(e), maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(context, e),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
