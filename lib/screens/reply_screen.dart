import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../data/mail_store.dart';
import '../data/models.dart';
import '../data/recipients.dart';
import '../services/claude_service.dart';
import '../services/google_auth.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/format.dart';
import '../widgets/timed_snack.dart';
import '../services/errors.dart';

/// 返信か全員に返信か転送か新規か
enum ComposeMode { reply, replyAll, forward, newMail }

/// ④ 返信画面（転送・新規メールの作成にも使う）
/// - キーボードなし：上下2段（上＝元メール、下＝返信欄＋🎤／Claudeボタン）
/// - キーボードあり：返信欄を全画面にし、元メールは上部に折りたたみ表示
class ReplyScreen extends StatefulWidget {
  const ReplyScreen({
    super.key,
    this.original,
    this.initialDraft,
    this.initialTo,
    this.initialSubject,
    this.mode = ComposeMode.reply,
  }) : assert(original != null || mode == ComposeMode.newMail);

  /// 元のメール（新規メールのときは null）
  final Mail? original;

  /// 返信（初期値）か転送か
  final ComposeMode mode;

  /// 最初から返信欄に入れておく下書き（AIボタンから使う）
  final String? initialDraft;

  /// 新規メールの最初の宛先・件名（AIボタンから使う）
  final String? initialTo;
  final String? initialSubject;

  @override
  State<ReplyScreen> createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  late final _controller = TextEditingController(text: widget.initialDraft ?? '');
  final _focusNode = FocusNode();

  /// 全員に返信のときの最初の宛先・CC（元メールから作る。自分は除く）
  late final _replyAllInit = widget.mode == ComposeMode.replyAll
      ? replyAllRecipients(widget.original!, googleAuth.user?.email)
      : null;

  /// 宛先（全員に返信・転送・新規メールのときに出す。全員に返信は入力済み）
  late final _toController = TextEditingController(text: _replyAllInit?.to.join(', ') ?? widget.initialTo ?? '');

  /// 転送のとき一緒に送る添付（最初は全部。チェックを外したものは送らない）
  late final Set<MailAttachment> _sendAttachments = {
    if (widget.mode == ComposeMode.forward) ...widget.original!.attachments,
  };

  /// Gmailで1通に付けられる添付の合計（25MB）
  static const _maxAttachmentBytes = 25 * 1024 * 1024;

  /// CC（全員に返信のときだけ出す。入力済み）
  late final _ccController = TextEditingController(text: _replyAllInit?.cc.join(', ') ?? '');

  /// 件名（新規メールのときだけ入力する）
  late final _subjectController = TextEditingController(text: widget.initialSubject ?? '');
  bool get _forward => widget.mode == ComposeMode.forward;
  bool get _newMail => widget.mode == ComposeMode.newMail;
  bool get _replyAll => widget.mode == ComposeMode.replyAll;

  /// 宛先の欄を出すか（ふつうの返信は元メールの送信元に送るので不要）
  bool get _needsTo => _forward || _newMail || _replyAll;
  bool _quoteExpanded = false;

  // ---- 音声入力（🎤）とClaudeへの音声指示 ----
  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false; // 🎤で聞き取り中
  bool _listeningForClaude = false; // Claudeへの指示を聞き取り中
  String _textBeforeListening = '';
  String _instruction = ''; // Claudeへの指示（画面に表示）
  bool _thinking = false; // Claudeが下書き中
  bool _claudeAsked = false;

  Future<bool> _ensureSpeech() async {
    if (_speechReady) return true;
    _speechReady = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() {
            _listening = false;
            _listeningForClaude = false;
          });
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _listening = false;
            _listeningForClaude = false;
          });
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('音声入力のエラー：${e.errorMsg}')));
        }
      },
    );
    if (!_speechReady && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('音声入力を使えません（マイクの許可を確認してください）')));
    }
    return _speechReady;
  }

  /// 🎤：話した内容を返信欄に入れる
  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!await _ensureSpeech()) return;
    _textBeforeListening = _controller.text;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: 'ja_JP',
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation),
    );
  }

  /// 話している途中の文字も、返信欄の末尾にそのまま表示する
  void _onSpeechResult(SpeechRecognitionResult result) {
    final base = _textBeforeListening;
    final words = result.recognizedWords;
    final text = base.isEmpty ? words : (base.endsWith('\n') ? '$base$words' : '$base\n$words');
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (result.finalResult) _textBeforeListening = text;
  }

  /// Claudeボタン：指示を音声で聞き取り、話し終えたらClaudeに頼む
  Future<void> _toggleClaudeListening() async {
    if (_listeningForClaude) {
      await _speech.stop(); // 止めると最後の結果が届き、そこでClaudeに頼む
      return;
    }
    if (!await _ensureSpeech()) return;
    setState(() {
      _instruction = '';
      _claudeAsked = false;
      _listeningForClaude = true;
    });
    await _speech.listen(
      onResult: (r) {
        setState(() => _instruction = r.recognizedWords);
        if (r.finalResult && !_claudeAsked && r.recognizedWords.trim().isNotEmpty) {
          _claudeAsked = true;
          _askClaude(r.recognizedWords);
        }
      },
      localeId: 'ja_JP',
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation),
    );
  }

  /// Claudeボタンの長押し：指示を文字で入力する
  Future<void> _typeInstruction() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Claudeへの指示'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '例：来週火曜の午後なら大丈夫と、丁寧に返信して'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('頼む')),
        ],
      ),
    );
    // ダイアログが閉じるアニメーション中は入力欄がまだ c を使っているので、少し待ってから破棄する
    Future<void>.delayed(const Duration(milliseconds: 500), c.dispose);
    if (text != null && text.trim().isNotEmpty) {
      setState(() => _instruction = text.trim());
      _askClaude(text.trim());
    }
  }

  Future<void> _askClaude(String instruction) async {
    if (_thinking) return;
    if (!await ensureAiConsent(context) || !mounted) return; // 初回だけ説明（2026-11-18）
    setState(() => _thinking = true);
    final before = _controller.text;
    final subjectBefore = _subjectController.text;
    try {
      String draft;
      if (_newMail) {
        final r = await ClaudeService.draftNewMail(
          instruction: instruction,
          currentDraft: before,
          currentSubject: subjectBefore,
          to: _toController.text,
        );
        draft = r.body;
        // 件名が空のときだけ、Claudeの件名の案を入れる
        if (subjectBefore.trim().isEmpty && r.subject.isNotEmpty) _subjectController.text = r.subject;
      } else {
        draft = await ClaudeService.draftReply(
          original: widget.original!,
          instruction: instruction,
          currentDraft: before,
          forward: _forward,
        );
      }
      if (!mounted) return;
      _controller.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
      showTimedSnack(context, 'Claudeが下書きしました', actionLabel: '元に戻す', onAction: () {
        _controller.text = before;
        _subjectController.text = subjectBefore;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  @override
  void dispose() {
    _speech.cancel();
    _controller.dispose();
    _toController.dispose();
    _ccController.dispose();
    _subjectController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _sending = false;

  /// 送信する本文（返信の下に元メールを「>」付きで引用する／転送なら転送の見出しを付けて元メールを付ける）
  String _composeText() {
    if (_newMail) return '${_controller.text.trimRight()}\n';
    final mail = widget.original!;
    if (_forward) {
      final note = _controller.text.trimRight();
      return '${note.isEmpty ? '' : '$note\n\n'}'
          '---------- Forwarded message ----------\n'
          'From: ${mail.senderName} <${mail.senderAddress}>\n'
          'Date: ${formatFull(mail.receivedAt)}\n'
          'Subject: ${mail.subject}\n\n'
          '${mail.body}\n';
    }
    final quoted = mail.body.split('\n').map((l) => '> $l').join('\n');
    return '${_controller.text.trimRight()}\n\n'
        '${formatFull(mail.receivedAt)} ${mail.senderName} <${mail.senderAddress}>:\n'
        '$quoted\n';
  }

  Future<void> _send() async {
    if (_sending) return;
    final messenger = ScaffoldMessenger.of(context);
    // 宛先（全員に返信・転送・新規）・CC（全員に返信）：カンマ・読点・空白区切りで複数可
    List<String> split(String text) => text
        .split(RegExp(r'[,、，;\s]+'))
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    final to = split(_toController.text);
    final cc = _replyAll ? split(_ccController.text) : <String>[];
    if (_needsTo) {
      if (to.isEmpty) {
        messenger.showSnackBar(SnackBar(
            content: Text(_forward ? '転送先のメールアドレスを入力してください' : '宛先のメールアドレスを入力してください')));
        return;
      }
      final bad = [...to, ...cc].where((a) => !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(a)).toList();
      if (bad.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('メールアドレスの形が正しくありません：${bad.join('、')}')));
        return;
      }
    }
    // 転送の添付：合計が大きすぎるときは送らない
    final files = _forward
        ? widget.original!.attachments.where(_sendAttachments.contains).toList()
        : <MailAttachment>[];
    final totalBytes = files.fold<int>(0, (sum, a) => sum + a.size);
    if (totalBytes > _maxAttachmentBytes) {
      messenger.showSnackBar(SnackBar(
          content: Text('添付が大きすぎます（合計${formatBytes(totalBytes)}、上限25MB）。いくつか外してください')));
      return;
    }
    if (!_forward && _controller.text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(_newMail ? '本文が空です' : '返信の本文が空です')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_forward ? '転送しますか？' : '送信しますか？'),
        content: Text(_forward
            ? '転送先：\n${to.join('\n')}'
                '${files.isEmpty ? '' : '\n\n添付：\n${files.map((a) => '${a.filename}（${a.sizeText}）').join('\n')}'}'
            : _replyAll
                ? '宛先：\n${to.join('\n')}${cc.isEmpty ? '' : '\n\nCC：\n${cc.join('\n')}'}'
            : _newMail
                ? '宛先：\n${to.join('\n')}\n\n件名：${_subjectController.text.trim().isEmpty ? '（なし）' : _subjectController.text.trim()}'
                : '宛先：${widget.original!.senderName}\n<${widget.original!.senderAddress}>'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('送信')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _sending = true);
    try {
      if (_newMail) {
        await mailStore.sendNew(to.join(', '), _subjectController.text.trim(), _composeText());
      } else if (_forward) {
        await mailStore.sendForward(widget.original!, to.join(', '), _composeText(), attachments: files);
      } else if (_replyAll) {
        await mailStore.sendReply(widget.original!, _composeText(), to: to.join(', '), cc: cc.join(', '));
      } else {
        await mailStore.sendReply(widget.original!, _composeText());
      }
      final done = _forward ? '転送しました' : '送信しました';
      messenger.showSnackBar(SnackBar(
        content: Text(mailStore.usingGmail ? done : '$done（ダミー：実際には送信していません）'),
      ));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text('送信できませんでした：${friendlyError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final theme = Theme.of(context);
    final mail = widget.original;

    // 注意：返信欄（TextField）はどちらのモードでも同じ位置に置き、
    // 切り替え時にフォーカスが外れてキーボードが閉じないようにしている
    return Scaffold(
      appBar: AppBar(
        title: Text(mail == null ? '新規メール' : '${_forward ? 'Fwd' : 'Re'}: ${mail.subject}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          _sending
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(icon: const Icon(Icons.send), tooltip: '送信', onPressed: _send),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 上段：元メール（新規メールのときはなし）
            if (mail != null) ...[
              if (keyboardOpen)
                _CollapsedQuote(
                  mail: mail,
                  expanded: _quoteExpanded,
                  onToggle: () => setState(() => _quoteExpanded = !_quoteExpanded),
                )
              else
                Expanded(child: _QuotePane(mail: mail)),
              const Divider(height: 1),
            ],
            // 下段：返信欄
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Text(_forward ? '転送先: ' : '宛先: ', style: theme.textTheme.bodySmall),
                        Expanded(
                          child: _needsTo
                              ? TextField(
                                  controller: _toController,
                                  keyboardType: TextInputType.emailAddress,
                                  autocorrect: false,
                                  style: theme.textTheme.bodyMedium,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    hintText: 'メールアドレス（複数はカンマ区切り）',
                                  ),
                                )
                              : Text('${mail!.senderName} <${mail!.senderAddress}>',
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
                  // 転送：元メールの添付（タップで付ける／外す）
                  if (_forward && mail != null && mail.attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final a in mail.attachments)
                              FilterChip(
                                avatar: const Icon(Icons.attach_file, size: 16),
                                label: Text('${a.filename}（${a.sizeText}）',
                                    overflow: TextOverflow.ellipsis),
                                selected: _sendAttachments.contains(a),
                                showCheckmark: true,
                                visualDensity: VisualDensity.compact,
                                onSelected: (on) => setState(
                                    () => on ? _sendAttachments.add(a) : _sendAttachments.remove(a)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_replyAll)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Row(
                        children: [
                          Text('CC: ', style: theme.textTheme.bodySmall),
                          Expanded(
                            child: TextField(
                              controller: _ccController,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              style: theme.textTheme.bodyMedium,
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: 'なし（複数はカンマ区切り）',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_newMail)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Row(
                        children: [
                          Text('件名: ', style: theme.textTheme.bodySmall),
                          Expanded(
                            child: TextField(
                              controller: _subjectController,
                              style: theme.textTheme.bodyMedium,
                              decoration: const InputDecoration(isDense: true, hintText: '件名'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          hintText: _forward
                              ? '転送に添えるメッセージ（なくても送れます）'
                              : _newMail
                                  ? '本文を入力（タップでキーボード）'
                                  : '返信を入力（タップでキーボード）',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  // Claudeへの指示と状態の表示
                  if (!keyboardOpen && (_listeningForClaude || _thinking || _instruction.isNotEmpty))
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          if (_thinking)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: SizedBox(
                                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          Expanded(
                            child: Text(
                              _thinking
                                  ? 'Claudeが下書き中…（指示：$_instruction）'
                                  : _listeningForClaude
                                      ? '指示を聞いています：$_instruction'
                                      : '指示：$_instruction',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!keyboardOpen)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: _listening
                                ? FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: theme.colorScheme.error),
                                    icon: const Icon(Icons.stop),
                                    label: const Text('聞き取り中…'),
                                    onPressed: _toggleListening,
                                  )
                                : FilledButton.tonalIcon(
                                    icon: const Icon(Icons.mic),
                                    label: const Text('音声入力'),
                                    onPressed:
                                        (_listeningForClaude || _thinking) ? null : _toggleListening,
                                  ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            // タップ：音声で指示／長押し：文字で指示
                            child: _listeningForClaude
                                ? FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: theme.colorScheme.error),
                                    icon: const Icon(Icons.stop),
                                    label: const Text('指示を聞き取り中'),
                                    onPressed: _toggleClaudeListening,
                                  )
                                : !ClaudeService.available
                                    // APIキーがないときは薄く表示し、押したら使い方の案内だけ出す（2026-11-18）
                                    ? OutlinedButton.icon(
                                        icon: const Icon(Icons.auto_awesome),
                                        label: const Text('Claude'),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: theme.colorScheme.outline,
                                        ),
                                        onPressed: () => showAiUnavailable(context),
                                      )
                                    : FilledButton.icon(
                                        icon: const Icon(Icons.auto_awesome),
                                        label: Text(_thinking ? '下書き中…' : 'Claude'),
                                        onPressed: (_listening || _thinking) ? null : _toggleClaudeListening,
                                        onLongPress: (_listening || _thinking) ? null : _typeInstruction,
                                      ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 上下2段のときの元メール表示
class _QuotePane extends StatelessWidget {
  const _QuotePane({required this.mail});

  final Mail mail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${mail.senderName}・${formatFull(mail.receivedAt)}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(mail.subject, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Text(mail.body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
          ],
        ),
      ),
    );
  }
}

/// キーボード表示中の折りたたみ元メール（タップで開閉）
class _CollapsedQuote extends StatelessWidget {
  const _CollapsedQuote({required this.mail, required this.expanded, required this.onToggle});

  final Mail mail;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: expanded
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: SingleChildScrollView(
                          child: Text(mail.body, style: theme.textTheme.bodySmall),
                        ),
                      )
                    : Text(mail.body.replaceAll('\n', ' '),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
