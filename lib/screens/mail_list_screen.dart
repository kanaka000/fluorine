import 'package:flutter/material.dart';

import '../data/mail_store.dart';
import '../data/models.dart';
import '../data/sender_merges.dart';
import '../widgets/format.dart';
import '../widgets/links/links.dart';
import '../widgets/sender_avatar.dart';
import '../widgets/timed_snack.dart';
import 'mail_detail_screen.dart';

/// ② ある送信元のメール一覧（新しい順）
class MailListScreen extends StatefulWidget {
  const MailListScreen({super.key, required this.address});

  final String address;

  @override
  State<MailListScreen> createState() => _MailListScreenState();
}

class _MailListScreenState extends State<MailListScreen> {
  String get address => widget.address;

  /// トップ画面に戻る準備中か（同じ処理を何度も始めないため）
  bool _leaving = false;

  /// この送信元のメールが全部なくなったら、「元に戻す」のお知らせが消えるのを待ってから
  /// トップ画面（送信元一覧）に戻る。「元に戻す」が押されてメールが戻っていれば、そのまま残る（2026-11-17）
  Future<void> _leaveWhenSnackCloses() async {
    if (_leaving) return;
    _leaving = true;
    // 本文画面の「メールを削除」から戻ったときなど、お知らせが出るのを少し待つ
    await Future<void>.delayed(const Duration(milliseconds: 300));
    while (true) {
      final closing = lastTimedSnackClosed;
      if (closing != null) await closing;
      if (!mounted) return;
      if (identical(closing, lastTimedSnackClosed)) break; // 待つ間に新しいお知らせが出ていなければ終わり
    }
    _leaving = false;
    if (mailStore.groupOf(address) != null) return; // 「元に戻す」でメールが戻った
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mailStore,
      builder: (context, _) {
        final group = mailStore.groupOf(address);
        if (group == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _leaveWhenSnackCloses());
          return Scaffold(
              appBar: AppBar(), body: const Center(child: Text('この送信元のメールはありません')));
        }
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                SenderAvatar(name: group.name, address: group.address, radius: 16),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group.name, style: theme.textTheme.titleMedium),
                      Text(
                          group.merged
                              ? '${group.addresses.length}件のアドレスをまとめています'
                              : group.address,
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'その他',
                onSelected: (v) {
                  if (v == 'merge') _chooseMerge(context, group);
                  if (v == 'unmerge') _unmerge(context, group);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'merge', child: Text('他の送信元とまとめる')),
                  if (group.merged) const PopupMenuItem(value: 'unmerge', child: Text('まとめを解除')),
                ],
              ),
            ],
          ),
          body: ListView.separated(
            itemCount: group.mails.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final mail = group.mails[i];
              final bold = mail.isRead ? FontWeight.normal : FontWeight.bold;
              // 左右どちらかにスワイプすると削除（ゴミ箱へ）
              return Dismissible(
                key: ValueKey(mail.id),
                background: const _DeleteBackground(alignment: Alignment.centerLeft),
                secondaryBackground: const _DeleteBackground(alignment: Alignment.centerRight),
                // 予定・タスクにリンクしているメールは、削除してよいか確かめる（2026-11-19）
                confirmDismiss: (_) => confirmDeleteLinkedMail(context, mail),
                onDismissed: (_) {
                  mailStore.trash(mail);
                  showTimedSnack(context, 'メールを削除しました',
                      actionLabel: '元に戻す', onAction: () => mailStore.untrash(mail));
                },
                child: ListTile(
                  leading: Icon(Icons.circle,
                      size: 10,
                      color: mail.isRead ? Colors.transparent : theme.colorScheme.primary),
                  minLeadingWidth: 10,
                  title: Text(mail.subject,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: bold)),
                  subtitle: group.merged
                      // まとめた一覧では、どのアドレスから来たかを小さく出す
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(mail.body.replaceAll('\n', ' '),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(mail.senderAddress,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.outline)),
                          ],
                        )
                      : Text(mail.body.replaceAll('\n', ' '),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(formatReceived(mail.receivedAt),
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: bold)),
                  onTap: () {
                    mailStore.markRead(mail);
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MailDetailScreen(mail: mail),
                    ));
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 「他の送信元とまとめる」：まとめる相手を選ぶ
Future<void> _chooseMerge(BuildContext context, SenderGroup group) async {
  final others = mailStore.groups.where((g) => g.address != group.address).toList();
  if (others.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('まとめられる送信元がありません')));
    return;
  }
  final picked = await showModalBottomSheet<Set<String>>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _MergePicker(group: group, others: others),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;
  final before = senderMerges.snapshot();
  senderMerges.merge(group.address, picked);
  showTimedSnack(context, '${picked.length}件の送信元を「${group.name}」にまとめました',
      actionLabel: '元に戻す', onAction: () => senderMerges.restore(before));
}

/// 「まとめを解除」
void _unmerge(BuildContext context, SenderGroup group) {
  final before = senderMerges.snapshot();
  senderMerges.unmerge(group.address);
  showTimedSnack(context, 'まとめを解除しました',
      actionLabel: '元に戻す', onAction: () => senderMerges.restore(before));
}

class _MergePicker extends StatefulWidget {
  const _MergePicker({required this.group, required this.others});

  final SenderGroup group;
  final List<SenderGroup> others;

  @override
  State<_MergePicker> createState() => _MergePickerState();
}

class _MergePickerState extends State<_MergePicker> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('「${widget.group.name}」にまとめる送信元を選ぶ',
                style: theme.textTheme.titleMedium),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final g in widget.others)
                  CheckboxListTile(
                    value: _selected.contains(g.address),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(g.address);
                      } else {
                        _selected.remove(g.address);
                      }
                    }),
                    secondary: SenderAvatar(name: g.name, address: g.address, radius: 16),
                    title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        g.merged ? '${g.addresses.length}件のアドレス' : g.address,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: FilledButton(
              onPressed: _selected.isEmpty ? null : () => Navigator.of(context).pop(_selected),
              child: Text(_selected.isEmpty ? '送信元を選んでください' : '${_selected.length}件をまとめる'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.error,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onError),
          const SizedBox(width: 8),
          Text('削除', style: TextStyle(color: Theme.of(context).colorScheme.onError)),
        ],
      ),
    );
  }
}
