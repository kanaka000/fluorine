import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/memo_store.dart';
import '../services/notion_sync.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/header_actions.dart';
import '../widgets/memo_ai.dart';
import '../widgets/memo_markdown.dart';
import '../widgets/timed_snack.dart';
import 'memo_detail_screen.dart';
import 'settings_screen.dart';

/// メモ（端末内に保存。更新日時の新しい順に、色付きのカードで表示）
class MemoScreen extends StatefulWidget {
  const MemoScreen({super.key});

  @override
  State<MemoScreen> createState() => _MemoScreenState();
}

class _MemoScreenState extends State<MemoScreen> {
  bool _aiBusy = false;

  // メモの設定で連携をオン／オフしたら、≡のメニューを作り直す
  @override
  void initState() {
    super.initState();
    appSettings.addListener(_refresh);
  }

  @override
  void dispose() {
    appSettings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// ≡の「Notionに今すぐ送る」
  Future<void> _sendToNotion(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (notionSync.pendingCount == 0) {
      messenger.showSnackBar(const SnackBar(content: Text('Notionに送っていないメモはありません')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Notionに送っています…')));
    await notionSync.flush();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(notionSync.lastError == null
          ? 'Notionに送りました'
          : 'Notionに送れませんでした：${notionSync.lastError}'),
    ));
  }

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: memoAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: memoAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runMemoAi(context, instruction, setBusy: (b) {
      if (mounted) setState(() => _aiBusy = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('メモ'),
        actions: headerActions(
          onAi: _aiByVoice,
          onAiLongPress: _aiByText,
          aiBusy: _aiBusy,
          menuItems: [
            if (notionSync.active)
              HeaderMenuItem(
                icon: Icons.cloud_upload_outlined,
                label: 'Notionに今すぐ送る',
                onTap: () => _sendToNotion(context),
              ),
            HeaderMenuItem(
              icon: Icons.settings_outlined,
              label: 'メモの設定',
              dividerBefore: notionSync.active,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MemoSettingsScreen()),
              ),
            ),
            HeaderMenuItem(
              icon: Icons.tune,
              label: '全体の設定',
              onTap: () => openGeneralSettings(context),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'メモを追加',
        onPressed: () => showAddMemoSheet(context, null),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: memoStore,
        builder: (context, _) {
          final memos = memoStore.memos;
          if (memos.isEmpty) {
            return const Center(
              child: Text('メモはありません\n右下の＋か、右上の ✨ で作れます', textAlign: TextAlign.center),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            children: [
              // 左右どちらかにスワイプすると削除（お知らせの「元に戻す」で戻せる）
              for (final m in memos)
                Dismissible(
                  key: ValueKey(m.id),
                  background: _swipeBackground(theme, Alignment.centerLeft),
                  secondaryBackground: _swipeBackground(theme, Alignment.centerRight),
                  onDismissed: (_) {
                    memoStore.remove(m);
                    showTimedSnack(context, 'メモを削除しました',
                        actionLabel: '元に戻す', onAction: () => memoStore.add(m));
                  },
                  child: _memoCard(m, theme),
                ),
            ],
          );
        },
      ),
    );
  }

  /// スワイプ中に見える赤い背景（ゴミ箱アイコン付き）
  Widget _swipeBackground(ThemeData theme, Alignment alignment) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignment,
      decoration: BoxDecoration(
        color: theme.colorScheme.error,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.delete_outline, color: theme.colorScheme.onError),
    );
  }

  Widget _memoCard(Memo m, ThemeData theme) {
    final bg = m.color?.cardColor(theme.brightness, theme.colorScheme.surface);
    final body = markdownToPlain(m.body).trim(); // 一覧では記号を外して表示
    return Card(
      color: bg,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => MemoDetailScreen(memo: m)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(m.title,
                        style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(formatMemoTime(m.updatedAt),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                ],
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
