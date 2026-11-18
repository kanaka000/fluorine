import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/reply_screen.dart';
import '../services/google_auth.dart';

/// リンクの種類（2026-11-18 セキュリティ対策 A04）
enum LinkKind { web, mailto, blocked }

/// 開いてよいかを調べたリンク
class SafeLink {
  const SafeLink._(this.kind, {this.uri, this.host = '', this.secure = false, this.confirm = false, this.address, this.subject});

  const SafeLink.blocked() : this._(LinkKind.blocked);

  final LinkKind kind;
  final Uri? uri;

  /// 実際の接続先（確認画面に出す）
  final String host;

  /// https か
  final bool secure;

  /// 開く前に接続先を見せて確認するか（http、または「ユーザー名@」付きの紛らわしいリンク）
  final bool confirm;

  /// mailto の宛先と件名
  final String? address;
  final String? subject;
}

/// リンクを調べる。https・http・mailto 以外（intent:・file:・content:・javascript:・data:・相対URLなど）は開かない
SafeLink classifyLink(String? url) {
  const blocked = SafeLink.blocked();
  if (url == null) return blocked;
  final s = url.trim();
  if (s.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(s)) return blocked;
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):').firstMatch(s);
  if (m == null) return blocked;
  final scheme = m[1]!.toLowerCase();
  final uri = Uri.tryParse(s);
  if (uri == null) return blocked;
  if (scheme == 'https' || scheme == 'http') {
    if (uri.host.isEmpty) return blocked;
    final secure = scheme == 'https';
    return SafeLink._(LinkKind.web,
        uri: uri, host: uri.host, secure: secure, confirm: !secure || uri.userInfo.isNotEmpty);
  }
  if (scheme == 'mailto') {
    String address;
    String? subject;
    try {
      address = Uri.decodeComponent(uri.path);
      subject = uri.queryParameters['subject'];
    } catch (_) {
      return blocked;
    }
    address = address.split(',').first.trim(); // 宛先は最初の1人だけ
    if (!RegExp(r'^[^\s@<>,;:"\\]+@[^\s@<>,;:"\\]+\.[^\s@<>,;:"\\]+$').hasMatch(address)) return blocked;
    subject = subject?.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
    return SafeLink._(LinkKind.mailto,
        address: address, subject: (subject == null || subject.isEmpty) ? null : subject);
  }
  return blocked;
}

/// メール本文・メモのリンクを開く（2026-11-18）
/// - https：そのまま外部のブラウザなどで開く
/// - http（暗号化なし）・「ユーザー名@」付きのリンク：接続先を見せて確認してから開く
/// - mailto：Fluorineの新規メールの画面を開く（宛先・件名を入れるだけ。送信は自分で押す）
/// - それ以外：開かずにお知らせを出す
/// HtmlWidget の onTapUrl にも使えるよう、いつも true（処理した）を返す
Future<bool> openSafeLink(BuildContext context, String? url) async {
  final link = classifyLink(url);
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String m) => messenger?.showSnackBar(SnackBar(content: Text(m)));

  switch (link.kind) {
    case LinkKind.blocked:
      say('このリンクは開けません（https・http・メールアドレス以外のリンクは開かない設定です）');
      return true;

    case LinkKind.mailto:
      if (!googleAuth.signedIn) {
        say('メールを作るには、Googleにログインしてください');
        return true;
      }
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReplyScreen(
          mode: ComposeMode.newMail,
          initialTo: link.address,
          initialSubject: link.subject,
        ),
      ));
      return true;

    case LinkKind.web:
      if (link.confirm) {
        final shown = url!.trim();
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(link.secure ? '接続先を確認してください' : '暗号化されていないリンクです'),
            content: SingleChildScrollView(
              child: Text('接続先：${link.host}\n\n'
                  '${link.uri!.userInfo.isNotEmpty ? '「@」より前の部分は接続先ではありません。\n\n' : ''}'
                  '${shown.length > 300 ? '${shown.substring(0, 300)}…' : shown}\n\n'
                  '開きますか？'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('開く')),
            ],
          ),
        );
        if (ok != true) return true;
      }
      try {
        final ok = await launchUrl(link.uri!, mode: LaunchMode.externalApplication);
        if (!ok) say('リンクを開けませんでした');
      } catch (_) {
        say('リンクを開けませんでした');
      }
      return true;
  }
}
