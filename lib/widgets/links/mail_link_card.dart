import 'package:material_ui/material_ui.dart';

import '../confirm_dialog.dart';
import '../../data/mail_store.dart';
import '../../data/models.dart';
import '../../screens/mail_detail_screen.dart';
import '../../services/errors.dart';
import '../../services/google_auth.dart';
import '../format.dart';
import '../timed_snack.dart';

// 予定・タスクの詳細画面の「リンクしたメール」とメールの選択（2026-11-19 の整理で分けた）

/// 予定・タスクの詳細画面の「リンクしたメール」（カードと「メールをリンク」ボタン）。
/// [onChanged] でリンクの一覧を保存する（Googleに送る。失敗したら例外）
class MailLinkSection extends StatefulWidget {
  const MailLinkSection({super.key, required this.links, required this.onChanged});

  final List<MailLinkRef> links;
  final Future<void> Function(List<MailLinkRef> links) onChanged;

  @override
  State<MailLinkSection> createState() => _MailLinkSectionState();
}

class _MailLinkSectionState extends State<MailLinkSection> {
  bool _saving = false;

  /// 読み込んだメール（null＝見つからない）。読み込み中・失敗は入らない
  final Map<String, Mail?> _mails = {};
  final Set<String> _failed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MailLinkSection old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    for (final ref in widget.links) {
      final id = ref.id;
      if (_mails.containsKey(id) || _failed.contains(id)) continue;
      final loaded = mailStore.loadedMail(id);
      if (loaded != null) {
        _mails[id] = loaded;
        continue;
      }
      try {
        final m = await mailStore.mailById(id);
        if (mounted) setState(() => _mails[id] = m);
      } catch (e) {
        devLog('リンクしたメールの読み込みに失敗: $e');
        if (mounted) setState(() => _failed.add(id));
      }
    }
  }

  Future<void> _save(List<MailLinkRef> links, String done) async {
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
      showTimedSnack(context, 'メールをリンクするには、Googleにログインしてください');
      return;
    }
    final mail = await pickMail(context, exclude: {for (final l in widget.links) l.id});
    if (mail == null || !mounted) return;
    _mails[mail.id] = mail;
    await _save([...widget.links, MailLinkRef(mail.id, mail.subject)], 'メールをリンクしました');
  }

  Future<void> _unlink(MailLinkRef ref) async {
    final ok = await askConfirm(context, title: 'リンクを外しますか？', message: '「${ref.subject}」へのリンクを外します。メールそのものは消えません。', okLabel: '外す');
    if (!ok || !mounted) return;
    await _save(widget.links.where((l) => !identical(l, ref)).toList(), 'リンクを外しました');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.links.isNotEmpty) ...[
          const Divider(height: 24),
          Text('リンクしたメール', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final ref in widget.links) _card(ref, theme),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.mail_outline),
            label: const Text('メールをリンク'),
            onPressed: _saving ? null : _add,
          ),
        ),
      ],
    );
  }

  Widget _card(MailLinkRef ref, ThemeData theme) {
    final scheme = theme.colorScheme;
    final loading = !_mails.containsKey(ref.id) && !_failed.contains(ref.id);
    final m = _mails[ref.id];
    if (!loading && m == null) {
      // 完全に消えたメール、または読み込めなかったメール
      final gone = !_failed.contains(ref.id);
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        color: scheme.surfaceContainerHighest,
        child: ListTile(
          leading: Icon(gone ? Icons.link_off : Icons.cloud_off, color: scheme.outline),
          title: Text(gone ? 'メールが見つかりません' : 'メールを読み込めませんでした',
              style: TextStyle(color: scheme.outline)),
          subtitle: Text(ref.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(onPressed: _saving ? null : () => _unlink(ref), child: const Text('外す')),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerHigh,
      child: ListTile(
        leading: const Icon(Icons.mail_outline),
        title: Text(m?.subject ?? ref.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          m == null ? '読み込み中…' : '${m.senderName}・${formatFull(m.receivedAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: m == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MailDetailScreen(mail: m))),
        onLongPress: _saving ? null : () => _unlink(ref),
      ),
    );
  }
}

/// 最近のメール（受信トレイ）から1通選ぶ。文字で絞り込める。[exclude] のIDは出さない
Future<Mail?> pickMail(BuildContext context, {Set<String> exclude = const {}}) {
  return showModalBottomSheet<Mail>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _MailPicker(exclude: exclude),
  );
}

class _MailPicker extends StatefulWidget {
  const _MailPicker({required this.exclude});

  final Set<String> exclude;

  @override
  State<_MailPicker> createState() => _MailPickerState();
}

class _MailPickerState extends State<_MailPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _q.trim().toLowerCase();
    final mails = mailStore
        .recentMails(300)
        .where((m) => !widget.exclude.contains(m.id))
        .where((m) =>
            q.isEmpty ||
            m.subject.toLowerCase().contains(q) ||
            m.senderName.toLowerCase().contains(q) ||
            m.senderAddress.toLowerCase().contains(q))
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
                child: Text('リンクするメールを選ぶ', style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '件名・差出人で絞り込む',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
              if (mails.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(q.isEmpty ? 'メールがありません' : '見つかりません',
                      style: TextStyle(color: theme.colorScheme.outline)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in mails)
                        ListTile(
                          leading: const Icon(Icons.mail_outline),
                          title: Text(m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${m.senderName}・${formatReceived(m.receivedAt)}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(context, m),
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

// ============ メールを削除する前の確認（リンクがあるとき。2026-11-19） ============
