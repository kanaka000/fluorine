import 'package:flutter/material.dart';

import '../data/mail_store.dart';
import '../data/models.dart';
import '../services/attachment_opener.dart';
import '../services/claude_service.dart';
import '../services/errors.dart';
import '../services/mail_search.dart';
import '../widgets/format.dart';
import 'mail_detail_screen.dart';

/// ✨の「メールを探して」の結果（2026-11-19）。
/// アーカイブも含めた全部のメールから、新しい順に50通まで。タップでメールの詳細を開く
class MailSearchScreen extends StatefulWidget {
  const MailSearchScreen({super.key, required this.search});

  final AiMailSearch search;

  @override
  State<MailSearchScreen> createState() => _MailSearchScreenState();
}

class _MailSearchScreenState extends State<MailSearchScreen> {
  late final String _query = buildMailQuery(widget.search);
  List<Mail>? _mails;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _mails = null;
      _error = null;
    });
    try {
      final found = await mailStore.searchMails(_query);
      if (mounted) setState(() => _mails = found);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mails = _mails;
    return Scaffold(
      appBar: AppBar(title: const Text('メールを探す')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 探した条件と、実際に Gmail に渡した検索文
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(describeMailSearch(widget.search), style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text('Gmailの検索：$_query',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                if (mails != null)
                  Text(
                      mails.length >= 50
                          ? '新しい順に50通まで表示しています'
                          : '${mails.length}通見つかりました（アーカイブも含む）',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body(theme, mails)),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, List<Mail>? mails) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('探せませんでした：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(onPressed: _run, child: const Text('もう一度')),
            ],
          ),
        ),
      );
    }
    if (mails == null) return const Center(child: CircularProgressIndicator());
    if (mails.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('見つかりませんでした。\n言葉を短くしたり、条件を減らしたりすると見つかることがあります。',
              textAlign: TextAlign.center),
        ),
      );
    }
    // 既読になったら太字を戻す
    return ListenableBuilder(
      listenable: mailStore,
      builder: (context, _) => ListView.separated(
        itemCount: mails.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) => _tile(theme, mails[i]),
      ),
    );
  }

  Widget _tile(ThemeData theme, Mail mail) {
    final bold = mail.isRead ? FontWeight.normal : FontWeight.bold;
    final files = mail.attachments.map((a) => attachmentDisplayName(a.filename)).join('、');
    return ListTile(
      leading: Icon(Icons.circle, size: 10, color: mail.isRead ? Colors.transparent : theme.colorScheme.primary),
      minLeadingWidth: 10,
      title: Text(mail.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mail.senderName, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (files.isNotEmpty)
            Text('📎 $files',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
      trailing: Text(formatReceived(mail.receivedAt), style: theme.textTheme.bodySmall?.copyWith(fontWeight: bold)),
      onTap: () {
        mailStore.markRead(mail);
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => MailDetailScreen(mail: mail)));
      },
    );
  }
}
