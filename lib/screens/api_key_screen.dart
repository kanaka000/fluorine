import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/ai/api_key_store.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/safe_link.dart';

// 全体の設定 → AI（✨）→ APIキー（2026-11-23）。
// キーをアプリの中で入れて、暗号化して保存する。入れ替えにビルドし直しは要らない

/// Anthropic のコンソールの API keys のページ
const _consoleKeysUrl = 'https://platform.claude.com/settings/keys';

/// 期限の選び方（コンソールで選んだものと同じものを選ぶ。3時間はアプリでは使わないので出さない）
enum _ExpiryChoice {
  days30('30日'),
  days7('7日'),
  days1('1日'),
  date('日付を選ぶ'),
  never('期限なし');

  const _ExpiryChoice(this.label);
  final String label;
}

class ApiKeyScreen extends StatefulWidget {
  const ApiKeyScreen({super.key});

  @override
  State<ApiKeyScreen> createState() => _ApiKeyScreenState();
}

class _ApiKeyScreenState extends State<ApiKeyScreen> {
  final _text = TextEditingController();
  bool _hidden = true;
  bool _saving = false;
  String? _error;
  _ExpiryChoice _choice = _ExpiryChoice.days30;
  DateTime? _pickedDate;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// 選んだ期限の日付（なし＝null）
  DateTime? get _expiry {
    final today = DateUtils.dateOnly(DateTime.now());
    return switch (_choice) {
      _ExpiryChoice.days30 => today.add(const Duration(days: 30)),
      _ExpiryChoice.days7 => today.add(const Duration(days: 7)),
      _ExpiryChoice.days1 => today.add(const Duration(days: 1)),
      _ExpiryChoice.date => _pickedDate,
      _ExpiryChoice.never => null,
    };
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = (data?.text ?? '').trim();
    if (!mounted) return;
    setState(() {
      _text.text = t;
      _error = t.isEmpty ? 'クリップボードが空です。コンソールでキーをコピーしてから押してください' : null;
    });
  }

  Future<void> _pickDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final d = await showDatePicker(
      context: context,
      initialDate: _pickedDate ?? now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: DateTime(now.year + 5),
    );
    if (d != null && mounted) setState(() => _pickedDate = d);
  }

  Future<void> _save() async {
    final key = _text.text.trim().replaceAll(RegExp(r'\s'), '');
    if (!key.startsWith('sk-ant-')) {
      setState(() => _error = 'APIキーではないようです（キーは「sk-ant-」で始まります）');
      return;
    }
    if (key.startsWith('sk-ant-admin')) {
      setState(() => _error = 'これは管理用のキー（Admin key）です。API keys のページで作った、ふつうのキーを入れてください');
      return;
    }
    if (_choice == _ExpiryChoice.date && _pickedDate == null) {
      setState(() => _error = '期限の日付を選んでください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final check = await checkApiKey(key);
    if (!mounted) return;
    if (check == KeyCheck.invalid) {
      setState(() {
        _saving = false;
        _error = 'このキーは使えませんでした（正しくないか、期限が切れているか、無効にされています）。保存していません';
      });
      return;
    }
    if (check == KeyCheck.unknown) {
      final ok = await askConfirm(
        context,
        title: 'キーを確かめられませんでした',
        message: '通信がつながらないか、Anthropic が混み合っているため、キーが使えるか確かめられませんでした。\n\n'
            'このまま保存しますか？（使えないキーだったときは、✨を押したときにお知らせします）',
        okLabel: '保存する',
      );
      if (!ok || !mounted) {
        setState(() => _saving = false);
        return;
      }
    }
    await apiKeyStore.save(key, _expiry);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _text.clear();
      _hidden = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(check == KeyCheck.ok
            ? 'APIキーを確かめて保存しました（クリップボードは空にしました）'
            : 'APIキーを保存しました（クリップボードは空にしました）')));
  }

  Future<void> _delete() async {
    final ok = await askConfirm(
      context,
      title: 'APIキーを消しますか？',
      message: 'この端末からキーを消します。消すと✨（AI）は使えなくなります（ほかの機能はそのまま使えます）。\n\n'
          'コンソールのキーそのものは消えません。もう使わないなら、コンソールで無効にするか削除してください。',
      okLabel: '消す',
    );
    if (!ok) return;
    await apiKeyStore.delete();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('APIキーを消しました')));
    }
  }

  String _date(DateTime d) => '${d.year}/${d.month}/${d.day}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('APIキー')),
      body: ListenableBuilder(
        listenable: apiKeyStore,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ---- 今のキー ----
            Card(
              child: ListTile(
                leading: Icon(apiKeyStore.available ? Icons.key : Icons.key_off_outlined,
                    color: apiKeyStore.invalid ? scheme.error : null),
                title: Text(apiKeyStore.available ? apiKeyStore.masked : 'キーが入っていません'),
                subtitle: Text(!apiKeyStore.available
                    ? '下の手順でキーを入れると、✨（AI）が使えます'
                    : apiKeyStore.invalid
                        ? 'このキーは使えませんでした。下の手順で新しいキーを入れてください'
                        : apiKeyStore.expiry == null
                            ? '期限：なし（または分かりません）'
                            : '期限：${_date(apiKeyStore.expiry!)}（目安）'),
                subtitleTextStyle: apiKeyStore.invalid
                    ? theme.textTheme.bodyMedium?.copyWith(color: scheme.error, fontWeight: FontWeight.bold)
                    : null,
                trailing: apiKeyStore.available
                    ? IconButton(
                        tooltip: 'キーを消す',
                        icon: Icon(Icons.delete_outline, color: scheme.error),
                        onPressed: _delete,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Text(apiKeyStore.available ? '新しいキーに入れ替える' : 'キーを入れる', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            // ---- 作り方の案内 ----
            Text(
              '1. 下の「コンソールを開く」で、Anthropic のコンソールの API keys のページを開き、ログインします'
              '（初めてなら、アカウントを作ってクレジットを買います）\n'
              '2.「Create key」を押し、名前（例：Fluorine スマホ）を付けて、期限を選びます\n'
              '3. 出てきたキー（sk-ant-…）をコピーします。キーが全部見えるのはこのときだけなので、'
              '画面を閉じる前にこのアプリに戻ってください\n'
              '4.「貼り付け」を押し、コンソールで選んだのと同じ期限を選んで「確かめて保存」を押します',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('コンソールを開く'),
                onPressed: () => openSafeLink(context, _consoleKeysUrl),
              ),
            ),
            const SizedBox(height: 16),
            // ---- 貼り付け ----
            TextField(
              controller: _text,
              obscureText: _hidden,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: 'APIキー',
                hintText: 'sk-ant-…',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon: IconButton(
                  tooltip: _hidden ? '見せる' : '隠す',
                  icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.content_paste),
                label: const Text('貼り付け'),
                onPressed: _saving ? null : _paste,
              ),
            ),
            // ---- 期限 ----
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('コンソールで選んだ期限'),
              subtitle: Text(_choice == _ExpiryChoice.date
                  ? (_pickedDate == null ? '日付を選んでください' : _date(_pickedDate!))
                  : _expiry == null
                      ? '期限のお知らせは出しません'
                      : '${_date(_expiry!)} まで（目安）'),
              trailing: DropdownButton<_ExpiryChoice>(
                value: _choice,
                items: _ExpiryChoice.values.map((c) => DropdownMenuItem(value: c, child: Text(c.label))).toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _choice = v);
                  if (v == _ExpiryChoice.date) _pickDate();
                },
              ),
              onTap: _choice == _ExpiryChoice.date ? _pickDate : null,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.verified_outlined),
              label: Text(_saving ? '確かめています…' : '確かめて保存'),
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: 24),
            Text(
              '・キーは、この端末の中だけに暗号化して保存します。画面には最後の4文字だけ出します\n'
              '・保存すると、クリップボードを空にします\n'
              '・「確かめて保存」では、料金のかからない問い合わせで、キーが使えるかを確かめます\n'
              '・残高（クレジット）はキーではなく Anthropic のアカウントに付いているので、キーを入れ替えてもそのまま使えます'
              '（クレジットそのものにも期限があります。コンソールの Billing で確かめられます）\n'
              '・期限の日付は目安です。正確な期限は、コンソールの API keys の表で確かめられます',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
