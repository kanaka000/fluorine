import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../data/app_settings.dart';
import '../services/claude_service.dart';

/// AIへの頼みごとを音声で聞き取る（タップ用）。
/// 下から出る画面で聞き取り、話し終えると頼みごとの文字を返す。途中で「文字で入力」にも切り替えられる。
Future<String?> listenInstruction(BuildContext context, {String hint = ''}) async {
  if (!await ensureAiConsent(context) || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _InstructionSheet(startWithVoice: true, hint: hint),
    ),
  );
}

/// AIへの頼みごとを文字で入力する（長押し用）
Future<String?> typeInstruction(BuildContext context, {String hint = ''}) async {
  if (!await ensureAiConsent(context) || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _InstructionSheet(startWithVoice: false, hint: hint),
    ),
  );
}

class _InstructionSheet extends StatefulWidget {
  const _InstructionSheet({required this.startWithVoice, required this.hint});

  final bool startWithVoice;
  final String hint;

  @override
  State<_InstructionSheet> createState() => _InstructionSheetState();
}

class _InstructionSheetState extends State<_InstructionSheet> {
  final _speech = SpeechToText();
  final _text = TextEditingController();
  late bool _voice = widget.startWithVoice;
  bool _listening = false;
  bool _done = false; // 結果を返した（画面を閉じた）
  String _heard = '';
  String? _message; // 「聞き取れませんでした」など

  @override
  void initState() {
    super.initState();
    if (_voice) WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  @override
  void dispose() {
    _speech.cancel();
    _text.dispose();
    super.dispose();
  }

  void _finish(String text) {
    if (_done || text.trim().isEmpty) return;
    _done = true;
    _speech.cancel();
    Navigator.of(context).pop(text.trim());
  }

  Future<void> _listen() async {
    setState(() {
      _heard = '';
      _message = null;
    });
    final ready = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted && !_done) {
          setState(() {
            _listening = false;
            if (_heard.trim().isEmpty) _message = '聞き取れませんでした。もう一度どうぞ。';
          });
        }
      },
      onError: (e) {
        if (mounted && !_done) {
          setState(() {
            _listening = false;
            _message = '音声入力のエラー：${e.errorMsg}';
          });
        }
      },
    );
    if (!mounted) return;
    if (!ready) {
      setState(() {
        _voice = false;
        _message = '音声入力を使えません（マイクの許可を確認してください）。文字で入力してください。';
      });
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (!mounted || _done) return;
        setState(() => _heard = r.recognizedWords);
        if (r.finalResult) _finish(r.recognizedWords);
      },
      localeId: 'ja_JP',
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation),
    );
  }

  void _switchToText() {
    _speech.cancel();
    setState(() {
      _voice = false;
      _listening = false;
      _message = null;
      if (_heard.isNotEmpty) _text.text = _heard;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('AIに頼む', style: theme.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 16),
          if (_voice) ...[
            Container(
              constraints: const BoxConstraints(minHeight: 72),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _heard.isNotEmpty
                    ? _heard
                    : (_listening ? '話してください…\n${widget.hint}' : widget.hint),
                style: _heard.isNotEmpty
                    ? theme.textTheme.bodyLarge
                    : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.keyboard),
                    label: const Text('文字で入力'),
                    onPressed: _switchToText,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _listening
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                          icon: const Icon(Icons.stop),
                          label: const Text('聞き取り中…'),
                          // 止めると最後の結果が届き、そこで頼む
                          onPressed: () => _speech.stop(),
                        )
                      : FilledButton.icon(
                          icon: const Icon(Icons.mic),
                          label: const Text('もう一度話す'),
                          onPressed: _listen,
                        ),
                ),
              ],
            ),
          ] else ...[
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(hintText: widget.hint),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('頼む'),
              onPressed: () => _finish(_text.text),
            ),
          ],
        ],
      ),
    );
  }
}

/// AIの答えを下から出す画面で表示する
void showAiAnswer(BuildContext context, String question, String answer) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(question,
                        style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(answer, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('閉じる'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// AIを初めて使うときに、何をどこへ送るかを説明して「使う」を押してもらう（2026-11-18 A06）。
/// 一度「使う」を押したら次からは出さない（「端末内のデータを消す」でもう一度出る）
Future<bool> ensureAiConsent(BuildContext context) async {
  // APIキーがないときは、説明ではなく使い方の案内を出す（2026-11-18）
  if (!ClaudeService.available) {
    await showAiUnavailable(context);
    return false;
  }
  if (appSettings.aiConsent) return true;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (c) => AlertDialog(
      title: const Text('AIを使う前に'),
      content: const SingleChildScrollView(
        child: Text('✨（AI）に頼むと、次の内容をAnthropic社のAI（Claude）に送ります。\n\n'
            '・頼みごとの文\n'
            '・開いているメール・予定・タスク・メモの内容（返信の下書きでは、元のメールの本文全体）\n'
            '・全体の設定の「✨にほかのタブの内容も見せる」がオンのときは、これからの予定・未完了のタスク・メモ・'
            '受信メール（最新100通の差出人・件名・本文の冒頭）\n\n'
            '送るときは、secrets.json に入れたAnthropicのAPIキーを使います（利用料はキーの持ち主にかかります）。'
            '音声での頼みごとは、端末の音声認識の仕組みで文字にします。\n\n'
            'AIは下書きや確認画面を出すだけで、送信・保存・削除は自分で押します。'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('使わない')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('使う')),
      ],
    ),
  );
  if (ok == true) appSettings.setAiConsent(true);
  return ok == true;
}

/// APIキーがないときに✨・Claudeボタンを押したら出す案内（2026-11-18）
Future<void> showAiUnavailable(BuildContext context) {
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (c) => AlertDialog(
      title: const Text('AIは使えません'),
      content: const Text('AI（Claude）を使うには、AnthropicのAPIキーが必要です。\n\n'
          'secrets.json の ANTHROPIC_API_KEY に自分のキーを入れて、'
          '--dart-define-from-file=secrets.json を付けて起動し直してください（利用料はキーの持ち主にかかります）。\n\n'
          'AIを使わなくても、ほかの機能はそのまま使えます。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('閉じる')),
      ],
    ),
  );
}
