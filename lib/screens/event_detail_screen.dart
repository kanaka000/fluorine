import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/calendar_store.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/calendar_ai.dart';
import '../widgets/header_actions.dart';

/// 予定の詳細（カレンダーの一覧で予定をタップすると開く）
class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({super.key, required this.event});

  final CalendarEvent event;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late CalendarEvent _event = widget.event;
  bool _aiBusy = false;
  bool _deleting = false;

  // ---------------- AIボタン ----------------

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: eventAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: eventAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runCalendarAi(
      context,
      instruction,
      selected: _event,
      setBusy: (b) {
        if (mounted) setState(() => _aiBusy = b);
      },
      onUpdated: (e) {
        if (mounted) setState(() => _event = e);
      },
      onDeleted: () {
        if (mounted) Navigator.of(context).pop(); // 削除したので一覧に戻る
      },
    );
  }

  // ---------------- 変更・削除 ----------------

  Future<void> _edit() async {
    final saved = await showEditEventSheet(context, _event);
    if (saved != null && mounted) setState(() => _event = saved);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final deleted = await confirmDeleteEvent(context, _event);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
    } else {
      setState(() => _deleting = false);
    }
  }

  Future<void> _openMap(String place) async {
    final uri = Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': place});
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = _event;
    final place = (e.location ?? '').trim();
    final note = (e.note ?? '').trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('予定'),
        actions: [
          AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
          IconButton(icon: const Icon(Icons.edit_outlined), tooltip: '変更', onPressed: _edit),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '削除',
            onPressed: _deleting ? null : _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(e.title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(formatEventWhen(e, withYear: true)),
            subtitle: e.recurring ? const Text('繰り返しの予定') : null,
          ),
          if (place.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text(place),
              subtitle: const Text('タップで地図を開く'),
              onTap: () => _openMap(place),
            ),
          if (note.isNotEmpty) ...[
            const Divider(height: 24),
            SelectableText(note, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('変更'),
                  onPressed: _edit,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('削除'),
                  onPressed: _deleting ? null : _delete,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('右上の ✨ で、この予定についてAIに頼めます（タップ＝音声、長押し＝文字）',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}
