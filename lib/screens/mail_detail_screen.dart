import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../data/app_settings.dart';
import '../data/mail_store.dart';
import '../data/models.dart';
import '../data/recipients.dart';
import '../services/claude_service.dart';
import '../services/google_auth.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_common.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/format.dart';
import '../widgets/header_actions.dart';
import '../widgets/link_ai.dart';
import '../widgets/links/links.dart';
import '../widgets/safe_link.dart';
import '../widgets/sender_avatar.dart';
import '../widgets/timed_snack.dart';
import 'reply_screen.dart';
import '../services/attachment_opener.dart';

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

  /// 添付ファイルの1行（2026-11-19）
  Widget _attachmentTile(ThemeData theme, MailAttachment a) {
    final openable = checkAttachment(a) == AttachmentCheck.ok;
    final color = openable ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.4);
    final sub = openable ? theme.colorScheme.onSurfaceVariant : color;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => openAttachment(context, mail, a),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(openable ? Icons.attach_file : Icons.block, size: 18, color: sub),
            const SizedBox(width: 8),
            Expanded(
              child: Text(attachmentDisplayName(a.filename),
                  style: theme.textTheme.bodyMedium?.copyWith(color: color)),
            ),
            const SizedBox(width: 8),
            Text(a.sizeText, style: theme.textTheme.bodySmall?.copyWith(color: sub)),
            if (openable) ...[
              const SizedBox(width: 8),
              Icon(Icons.open_in_new, size: 16, color: theme.colorScheme.primary),
            ],
          ],
        ),
      ),
    );
  }

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

  /// HTMLメールを文字だけで表示しているか（表示が崩れるメール用。2026-11-19）
  bool _textView = false;

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

  // 表の直し（2026-11-19）。毎回作り直さないよう覚えておく
  String? _tableSource;
  String? _tableHtml;
  String _fixedTables(String html) {
    if (_tableSource != html) {
      _tableSource = html;
      _tableHtml = fixHtmlTableCells(html);
    }
    return _tableHtml!;
  }

  /// HTMLメールの表示
  /// - ライトモード、または「元の色で表示」中：メールは白背景前提で作られているので、白い紙の上に表示する
  /// - ダークモード：メール側の文字色・背景色を外して、アプリの暗い配色で表示する
  Widget _htmlBody(String rawHtml) {
    final html = _fixedTables(rawHtml);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final darkView = isDark && !_originalColors;
    final hasImages = html.toLowerCase().contains('<img');
    // 「テキストで表示」ボタン（いつも出す。元の色で表示の右）
    final textToggle = TextButton.icon(
      icon: Icon(_textView ? Icons.web_outlined : Icons.notes),
      label: Text(_textView ? 'HTMLで表示' : 'テキストで表示'),
      onPressed: () => setState(() => _textView = !_textView),
    );
    if (_textView) {
      // 文字だけの表示：テキスト版があればそれ、なければHTMLから取り出した文字（mail.body）
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          textToggle,
          SelectableText(mail.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              textToggle,
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

  static const _aiHint = '例：これを予定に入れて／タスクにして、期限は金曜／要点をメモにして／了解と返信して／打ち合わせの予定にリンクして／何が言いたいの？';
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
    final result = await askAiWithStatus(
      context,
      instruction,
      setBusy: (b) {
        if (mounted) setState(() => _aiBusy = b);
      },
      ask: () async {
        await mailStore.ensureBody(mail); // 本文の全文がまだなら先に取る
        return ClaudeService.askAboutMail(mail: mail, instruction: instruction);
      },
    );
    if (result == null || !mounted) return;

    // 結果に合わせて、入力済みの画面を開く（保存・送信は自分で押す）
    switch (result) {
      case AiReply r:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ReplyScreen(original: mail, initialDraft: r.body),
        ));
      case AiLink r:
        await runLinkAi(context, r, mail: mail);
      default:
        await handleCommonAiResult(context, instruction, result, mail: mail);
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
  Future<void> _delete(BuildContext context) async {
    // 予定・タスクにリンクしているメールは、削除してよいか確かめる（2026-11-19）
    if (!await confirmDeleteLinkedMail(context, mail) || !context.mounted) return;
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
          // このメールにリンクしている予定・タスク（ボタンのすぐ下。2026-11-19）
          MailBacklinkSection(mailId: mail.id, subject: mail.subject),
          const Divider(height: 32),
          if (!mail.bodyLoaded) const LinearProgressIndicator(),
          if (mail.html != null && mail.html!.length > _maxHtml && !_showLargeHtml)
            _largeHtmlNotice(theme)
          else if (mail.html != null)
            _htmlBody(mail.html!)
          else
            SelectableText(mail.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
          // 添付ファイルの一覧。決めた種類だけタップで外部アプリで開く（2026-11-19）。
          // 開けない種類は薄く表示し、タップすると理由を案内する。転送するときに一緒に送れる
          if (mail.attachments.isNotEmpty) ...[
            const Divider(height: 32),
            Text('添付ファイル（${mail.attachments.length}）', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final a in mail.attachments) _attachmentTile(theme, a),
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

/// 表のマス（td・th）の style から、display:block／inline-block とピクセルで決めた幅を外す（2026-11-19）。
/// メールのひな形には「td に display:block; width:580px」と書くものがあり、
/// HTMLの表示部品がそのマスを表のマスとして扱えず、本文が丸ごと表示されないことがあったため
/// （HANA TAXI の予約確認メールで発生）。display:none は残す
String fixHtmlTableCells(String html) {
  final display = RegExp(r'(^|;)\s*display\s*:\s*(block|inline-block)\s*(!important)?\s*(?=;|$)', caseSensitive: false);
  final width = RegExp(r'(^|;)\s*(max-|min-)?width\s*:\s*[\d.]+px\s*(!important)?\s*(?=;|$)', caseSensitive: false);
  final styleAttr = RegExp(r"""(style\s*=\s*)("[^"]*"|'[^']*')""", caseSensitive: false);
  return html.replaceAllMapped(RegExp(r'<(td|th)\b[^>]*>', caseSensitive: false), (tag) {
    return tag[0]!.replaceFirstMapped(styleAttr, (m) {
      final v = m[2]!;
      final q = v[0];
      final css = v
          .substring(1, v.length - 1)
          .replaceAllMapped(display, (x) => x[1]!)
          .replaceAllMapped(width, (x) => x[1]!)
          .replaceAll(RegExp(r';{2,}'), ';')
          .replaceAll(RegExp(r'^;|;$'), '');
      return '${m[1]}$q$css$q';
    });
  });
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
