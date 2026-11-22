import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/contacts_service.dart';

// 宛先・CCの欄（2026-11-22 の10）。打っている語から候補を出し、タップでアドレスに置き換える。
// 候補：Googleの連絡先 → その他の連絡先 → 受信メールの送信元（受信メールはすぐ、連絡先は打つ手が止まってから）。
// 連絡先を読む許可がまだなければ、許可画面はいきなり出さず、候補の下の「Googleの連絡先も探す」を押したときだけ求める

/// 宛先の区切り（送信のときの分け方と同じ）
final _separator = RegExp(r'[,、，;\s]');

/// 「連絡先も探す」で許可を断ったら、アプリを開いている間はボタンを出さない
bool _contactsDeclined = false;

class RecipientField extends StatefulWidget {
  const RecipientField({super.key, required this.label, required this.controller, required this.hintText});

  /// 欄の左の文字（「宛先: 」「CC: 」など）
  final String label;
  final TextEditingController controller;
  final String hintText;

  @override
  State<RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<RecipientField> {
  final _focus = FocusNode();
  Timer? _timer;
  int _gen = 0;
  String _query = '';
  List<ContactCandidate> _local = const [];
  List<ContactCandidate> _remote = const [];
  bool _searching = false;
  bool _noPermission = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _focus.addListener(_onChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  /// カーソルのある語（区切りから区切りまで）
  ({int start, int end, String text}) _token() {
    final text = widget.controller.text;
    var cursor = widget.controller.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    var start = cursor;
    while (start > 0 && !_separator.hasMatch(text[start - 1])) {
      start--;
    }
    var end = cursor;
    while (end < text.length && !_separator.hasMatch(text[end])) {
      end++;
    }
    return (start: start, end: end, text: text.substring(start, end).trim());
  }

  /// 欄に入っているほかのアドレス（候補から外す）
  Set<String> _entered() {
    final t = _token();
    final text = widget.controller.text;
    final others = '${text.substring(0, t.start)} ${text.substring(t.end)}';
    return {
      for (final a in others.split(_separator))
        if (a.trim().isNotEmpty) a.trim().toLowerCase(),
    };
  }

  /// 連絡先も探すのは、2文字以上か日本語などを含むとき（1文字の英字では多すぎる）
  bool _remoteWorthy(String q) => q.length >= 2 || q.codeUnits.any((c) => c > 127);

  void _onChanged() {
    final q = _focus.hasFocus ? _token().text : '';
    if (q == _query) {
      if (mounted) setState(() {}); // フォーカスの出入りで候補を出す・消す
      return;
    }
    _query = q;
    _timer?.cancel();
    final gen = ++_gen;
    _remote = const [];
    _searching = false;
    if (q.isEmpty) {
      setState(() => _local = const []);
      return;
    }
    setState(() => _local = ContactsService.fromMails(q));
    if (_remoteWorthy(q)) {
      _timer = Timer(const Duration(milliseconds: 400), () => _searchRemote(q, gen));
    }
  }

  Future<void> _searchRemote(String q, int gen) async {
    if (!mounted || gen != _gen) return;
    setState(() => _searching = true);
    final r = await ContactsService.searchContacts(q);
    if (!mounted || gen != _gen) return;
    setState(() {
      _searching = false;
      _remote = r.list;
      _noPermission = r.noPermission;
    });
  }

  Future<void> _allowContacts() async {
    final ok = await ContactsService.requestPermission();
    if (!mounted) return;
    if (!ok) {
      setState(() => _contactsDeclined = true);
      return;
    }
    setState(() => _noPermission = false);
    _focus.requestFocus();
    if (_query.isNotEmpty) _searchRemote(_query, _gen);
  }

  List<ContactCandidate> _candidates() {
    final used = _entered();
    final seen = <String>{};
    return [
      for (final c in [..._remote, ..._local])
        if (!used.contains(c.address.toLowerCase()) && seen.add(c.address.toLowerCase())) c,
    ].take(5).toList();
  }

  /// 候補をタップ：打ちかけの語をアドレスに置き換え、「, 」を足して続けて打てるようにする
  void _pick(ContactCandidate c) {
    final t = _token();
    final text = widget.controller.text;
    final before = text.substring(0, t.start);
    final after = text.substring(t.end).replaceFirst(RegExp(r'^[,、，;\s]*'), '');
    final insert = '${c.address}, ';
    widget.controller.value = TextEditingValue(
      text: before + insert + after,
      selection: TextSelection.collapsed(offset: before.length + insert.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _focus.hasFocus && _query.isNotEmpty;
    final list = active ? _candidates() : const <ContactCandidate>[];
    final showAllow = active && _noPermission && !_contactsDeclined;
    final showSearching = active && _searching && list.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(widget.label, style: theme.textTheme.bodySmall),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(isDense: true, hintText: widget.hintText),
              ),
            ),
          ],
        ),
        if (list.isNotEmpty || showAllow || showSearching)
          // 候補をタップしても欄のフォーカスが外れないように
          TextFieldTapRegion(
            child: Container(
              margin: const EdgeInsets.only(top: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 2),
                children: [
                  for (final c in list) _tile(theme, c),
                  if (showSearching)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text('連絡先を探しています…', style: theme.textTheme.bodySmall),
                    ),
                  if (showAllow)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _allowContacts,
                        icon: const Icon(Icons.contacts_outlined, size: 18),
                        label: const Text('Googleの連絡先も探す'),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _tile(ThemeData theme, ContactCandidate c) {
    final icon = switch (c.source) {
      '連絡先' => Icons.person,
      'その他の連絡先' => Icons.person_outline,
      _ => Icons.mail_outline,
    };
    final sameAsAddress = c.name.trim().toLowerCase() == c.address.toLowerCase();
    return InkWell(
      onTap: () => _pick(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sameAsAddress ? c.address : c.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                  if (!sameAsAddress)
                    Text(c.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
