import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';


import '../data/app_settings.dart';
import '../data/mail_store.dart';
import '../data/models.dart';
import '../data/recipients.dart';
import '../services/claude_service.dart';
import '../services/google_auth.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/format.dart';
import '../widgets/general_ai.dart';
import '../widgets/header_actions.dart';
import '../widgets/safe_link.dart';
import '../widgets/sender_avatar.dart';
import '../widgets/timed_snack.dart';
import 'reply_screen.dart';
import '../services/errors.dart';

/// ③ メール本文
class MailDetailScreen extends StatefulWidget {
  const MailDetailScreen({super.key, required this.mail});

  final Mail mail;

  @override
  State<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends State<MailDetailScreen> {
  Mail get mail => widget.mail;

  /// メール内の画像を表示するか（初期値は設定に従う）
  late bool _showImages = appSettings.loadImages;

  /// リンクは https はそのまま、http は確認してから、mailto は新規メールで開く。それ以外は開かない（2026-11-18）
  Future<bool> _openLink(String url) => openSafeLink(context, url);

  /// とても大きなHTMLメールは、固まったり落ちたりしないよう文字だけで表示する（2026-11-18 B06）
  static const _maxHtml = 1000000;
  bool _showLargeHtml = false;

  Widget _largeHtmlNotice(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('大きいメールなので、文字だけで表示しています', style: theme.textTheme.bodySmall),
        TextButton.icon(
          icon: const Icon(Icons.web_outlined),
          label: const Text('そのまま表示（時間がかかることがあります）'),
          onPressed: () => setState(() => _showLargeHtml = true),
        ),
        const SizedBox(height: 8),
        SelectableText(mail.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
      ],
    );
  }

  /// ダークモードでも、HTMLメールを元の色（白い背景）で表示するか。このメールを開いている間だけ有効
  bool _originalColors = false;

  /// 暗く表示するために色を外したHTML（毎回作り直さないよう取っておく）
  String? _darkSource;
  String? _darkHtml;

  String _darkVersion(String html) {
    if (_darkSource != html) {
      _darkSource = html;
      _darkHtml = stripHtmlColors(html);
    }
    return _darkHtml!;
  }

  /// HTMLメールの表示
  /// - ライトモード、または「元の色で表示」中：メールは白背景前提で作られているので、白い紙の上に表示する
  /// - ダークモード：メール側の文字色・背景色を外して、アプリの暗い配色で表示する
  Widget _htmlBody(String html) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final darkView = isDark && !_originalColors;
    final hasImages = html.toLowerCase().contains('<img');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ((hasImages && !_showImages) || isDark)
          Wrap(
            spacing: 4,
            children: [
              if (hasImages && !_showImages)
                TextButton.icon(
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('画像を表示'),
                  onPressed: () => setState(() => _showImages = true),
                ),
              if (isDark)
                TextButton.icon(
                  icon: Icon(_originalColors ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
                  label: Text(_originalColors ? '暗い色で表示' : '元の色で表示'),
                  onPressed: () => setState(() => _originalColors = !_originalColors),
                ),
            ],
          ),
        Container(
          width: double.infinity,
          padding: darkView ? EdgeInsets.zero : const EdgeInsets.all(8),
          decoration: darkView
              ? null
              : BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
          child: HtmlWidget(
            darkView ? _darkVersion(html) : html,
            key: ValueKey('$_showImages-$darkView'),
            textStyle: TextStyle(
              color: darkView ? theme.colorScheme.onSurface : const Color(0xFF202124),
              fontSize: 15,
              height: 1.5,
            ),
            onTapUrl: _openLink,
            // 暗く表示しているときは、リンクを暗い背景で読める色にする
            customStylesBuilder: darkView
                ? (element) => element.localName == 'a' ? {'color': '#8AB4F8'} : null
                : null,
            // 画像をオフにしているときは、画像を読み込まずに空にする
            // 画像をオフにしているときは、画像を読み込まずに空にする。
            // 表示するときも https の画像だけ（file:・data:・http: などは読まない。2026-11-18 B06）
            customWidgetBuilder: (element) {
              if (element.localName != 'img') return null;
              if (!_showImages) return const SizedBox.shrink();
              final src = (element.attributes['src'] ?? '').trim();
              final uri = Uri.tryParse(src);
              final ok = uri != null && uri.scheme.toLowerCase() == 'https' && uri.host.isNotEmpty;
              return ok ? null : const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    mailStore.ensureBody(mail); // Gmailのメールなら本文の全文を取得
  }

  // ---------------- AIボタン ----------------

  static const _aiHint = '例：これを予定に入れて／タスクにして、期限は金曜／要点をメモにして／了解と返信して／何が言いたいの？／明日の予定は？';
  bool _aiBusy = false;

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: _aiHint);
    if (text != null) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: _aiHint);
    if (text != null) _runAi(text);
  }

  Future<void> _runAi(String instruction) async {
    if (_aiBusy) return;
    setState(() => _aiBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text('AIが考えています…（$instruction）'),
      duration: const Duration(seconds: 30),
    ));
    AiResult result;
    try {
      await mailStore.ensureBody(mail); // 本文の全文がまだなら先に取る
      result = await ClaudeService.askAboutMail(mail: mail, instruction: instruction);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      if (mounted) {
        setState(() => _aiBusy = false);
        messenger.showSnackBar(SnackBar(content: Text('AIに頼めませんでした：${friendlyError(e)}')));
      }
      return;
    }
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    setState(() => _aiBusy = false);

    // 結果に合わせて、入力済みの画面を開く（保存・送信は自分で押す）
    switch (result) {
      case AiEvent r:
        showAddEventSheet(context, mail,
            title: r.title,
            date: r.date,
            time: r.time,
            endDate: r.endDate,
            endTime: r.endTime,
            allDay: (r.allDay ?? false) || r.time == null,
            location: r.location,
            note: r.note);
      case AiTask r:
        showAddTaskSheet(context, mail, title: r.title, due: r.due, note: r.note);
      case AiMemo r:
        showAddMemoSheet(context, mail, title: r.title, body: r.body);
      case AiReply r:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ReplyScreen(original: mail, initialDraft: r.body),
        ));
      case AiNewMail r:
        await openNewMailFromAi(context, r);
      case AiAnswer r:
        showAiAnswer(context, instruction, r.text);
      case AiDeleteEvent _ || AiTaskUpdate _ || AiTaskComplete _ || AiTaskDelete _ || AiMemoUpdate _ || AiMemoDelete _:
        showAiAnswer(context, instruction, '予定・タスク・メモの変更や削除は、それぞれの画面から頼んでください。');
    }
  }

  void _openCompose(BuildContext context, ComposeMode mode) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReplyScreen(original: mail, mode: mode),
    ));
  }

  /// 返信ボタンの長押し：返信／全員に返信／転送を選ぶ
  /// 「全員に返信」は、自分と送信元のほかにも相手がいるメールのときだけ出す
  Future<void> _chooseCompose(BuildContext context) async {
    final canReplyAll = hasOtherRecipients(mail, googleAuth.user?.email);
    final mode = await showModalBottomSheet<ComposeMode>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('返信'),
              onTap: () => Navigator.of(ctx).pop(ComposeMode.reply),
            ),
            if (canReplyAll)
              ListTile(
                leading: const Icon(Icons.reply_all),
                title: const Text('全員に返信'),
                onTap: () => Navigator.of(ctx).pop(ComposeMode.replyAll),
              ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('転送'),
              onTap: () => Navigator.of(ctx).pop(ComposeMode.forward),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode != null && context.mounted) _openCompose(context, mode);
  }

  /// メールを削除（ゴミ箱へ）。本文画面を閉じたあとの一覧の画面に「元に戻す」付きのお知らせを出す
  void _delete(BuildContext context) {
    // 画面を閉じると context が使えなくなるので、お知らせの出し先を先に取っておく
    final messenger = ScaffoldMessenger.of(context);
    final target = mail;
    Navigator.of(context).pop();
    mailStore.trash(target);
    showTimedSnackOn(messenger, 'メールを削除しました',
        actionLabel: '元に戻す', onAction: () => mailStore.untrash(target));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mailStore,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          // タップ＝音声で頼む、長押し＝文字で頼む
          AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(mail.subject, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          Row(
            children: [
              SenderAvatar(name: mail.senderName, address: mail.senderAddress, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(mail.senderName, style: theme.textTheme.titleSmall),
                    Text(mail.senderAddress, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Text(formatFull(mail.receivedAt), style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
          // メールから予定・タスク・メモを作る
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Icons.event, size: 18),
                label: const Text('予定に追加'),
                onPressed: () => showAddEventSheet(context, mail),
              ),
              ActionChip(
                avatar: const Icon(Icons.check_box_outlined, size: 18),
                label: const Text('タスクに追加'),
                onPressed: () => showAddTaskSheet(context, mail),
              ),
              ActionChip(
                avatar: const Icon(Icons.sticky_note_2_outlined, size: 18),
                label: const Text('メモに追加'),
                onPressed: () => showAddMemoSheet(context, mail),
              ),
              ActionChip(
                avatar: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                label: Text('メールを削除', style: TextStyle(color: theme.colorScheme.error)),
                onPressed: () => _delete(context),
              ),
            ],
          ),
          const Divider(height: 32),
          if (!mail.bodyLoaded) const LinearProgressIndicator(),
          if (mail.html != null && mail.html!.length > _maxHtml && !_showLargeHtml)
            _largeHtmlNotice(theme)
          else if (mail.html != null)
            _htmlBody(mail.html!)
          else
            SelectableText(mail.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
          // 添付ファイルの一覧（表示だけ。転送するときに一緒に送れる）
          if (mail.attachments.isNotEmpty) ...[
            const Divider(height: 32),
            Text('添付ファイル（${mail.attachments.length}）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final a in mail.attachments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.attach_file, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(child: Text(a.filename, style: theme.textTheme.bodyMedium)),
                    const SizedBox(width: 8),
                    Text(a.sizeText, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ],
      ),
      // タップ＝返信、長押し＝「返信／転送」を選ぶ
      floatingActionButton: GestureDetector(
        onLongPress: () => _chooseCompose(context),
        child: FloatingActionButton.extended(
          icon: const Icon(Icons.reply),
          label: const Text('返信'),
          onPressed: () => _openCompose(context, ComposeMode.reply),
        ),
      ),
    );
  }
}

/// HTMLメールから文字色・背景色の指定を外す（ダークモードで暗く表示するため）
/// style属性・<style>の中の color／background／background-color と、bgcolor・color 属性を取り除く
String stripHtmlColors(String html) {
  final colorDecl = RegExp(
      r'(?<![-\w])(background-color|background|color)\s*:\s*[^;"\x27}]*(;|(?=["\x27}]))',
      caseSensitive: false);
  var s = html.replaceAllMapped(
    RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
    (m) => m[0]!.replaceAll(colorDecl, ''),
  );
  s = s.replaceAllMapped(
    RegExp(r'(style\s*=\s*)("[^"]*"|\x27[^\x27]*\x27)', caseSensitive: false),
    (m) => '${m[1]}${m[2]!.replaceAll(colorDecl, '')}',
  );
  s = s.replaceAllMapped(
    RegExp(r'<[a-zA-Z][^>]*>'),
    (m) => m[0]!.replaceAll(
        RegExp(r'\s(bgcolor|color)\s*=\s*("[^"]*"|\x27[^\x27]*\x27|[^\s>]+)', caseSensitive: false), ''),
  );
  return s;
}
