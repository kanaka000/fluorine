import 'dart:convert';

import 'package:googleapis/gmail/v1.dart';
import 'package:http/http.dart' as http;

import '../data/models.dart';
import 'errors.dart';

/// Gmail APIとのやり取り
class GmailService {
  GmailService(http.Client client) : _api = GmailApi(client);

  final GmailApi _api;

  /// 受信トレイの新しいメールを取得する（本文は概要だけ。全文は開いたときに取得）
  Future<List<Mail>> fetchInbox({int max = 100}) async {
    final list = await _api.users.messages.list('me', labelIds: ['INBOX'], maxResults: max);
    final ids = (list.messages ?? []).map((m) => m.id!).toList();
    final result = <Mail>[];
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.skip(i).take(10);
      final msgs = await Future.wait(chunk.map((id) => _api.users.messages
          .get('me', id, format: 'metadata', metadataHeaders: ['From', 'To', 'Cc', 'Subject', 'Message-ID', 'References'])));
      result.addAll(msgs.map(_toMail));
    }
    return result;
  }

  // ---------------- 差分取得（Gmailの履歴API） ----------------

  /// 今の履歴ID（この時点より後の変更を、次回に差分で取るための目印）
  Future<String?> currentHistoryId() async {
    final profile = await _api.users.getProfile('me');
    return profile.historyId;
  }

  /// [startHistoryId] より後に変更があったメールのIDを集める。
  /// 履歴が古すぎて取れないとき（Gmailは約1週間分しか残さない）は null を返す（→ 全部読み込み直す）
  Future<({Set<String> changed, String? historyId})?> changesSince(String startHistoryId) async {
    final changed = <String>{};
    String? pageToken;
    String? latest;
    try {
      do {
        final res = await _api.users.history.list(
          'me',
          startHistoryId: startHistoryId,
          pageToken: pageToken,
          maxResults: 500,
        );
        for (final h in res.history ?? <History>[]) {
          for (final m in h.messages ?? <Message>[]) {
            if (m.id != null) changed.add(m.id!);
          }
          for (final a in h.messagesAdded ?? <HistoryMessageAdded>[]) {
            if (a.message?.id != null) changed.add(a.message!.id!);
          }
          for (final d in h.messagesDeleted ?? <HistoryMessageDeleted>[]) {
            if (d.message?.id != null) changed.add(d.message!.id!);
          }
          for (final l in h.labelsAdded ?? <HistoryLabelAdded>[]) {
            if (l.message?.id != null) changed.add(l.message!.id!);
          }
          for (final l in h.labelsRemoved ?? <HistoryLabelRemoved>[]) {
            if (l.message?.id != null) changed.add(l.message!.id!);
          }
        }
        latest = res.historyId ?? latest;
        pageToken = res.nextPageToken;
      } while (pageToken != null);
    } on DetailedApiRequestError catch (e) {
      if (e.status == 404) return null; // 履歴が古すぎる
      rethrow;
    }
    return (changed: changed, historyId: latest);
  }

  /// 1通の最新の状態を取る。削除済み（見つからない）なら null。
  /// 受信トレイにある（ゴミ箱・迷惑メールではない）なら Mail、そうでなければ inInbox=false
  Future<({Mail? mail, bool inInbox})> fetchState(String id) async {
    try {
      final m = await _api.users.messages
          .get('me', id, format: 'metadata', metadataHeaders: ['From', 'To', 'Cc', 'Subject', 'Message-ID', 'References']);
      final labels = m.labelIds ?? const <String>[];
      final inInbox = labels.contains('INBOX') && !labels.contains('TRASH') && !labels.contains('SPAM');
      return (mail: inInbox ? _toMail(m) : null, inInbox: inInbox);
    } on DetailedApiRequestError catch (e) {
      if (e.status == 404) return (mail: null, inInbox: false);
      rethrow;
    }
  }

  /// メール本文の全文を取得する（テキスト版と、あればHTML版）
  Future<({String text, String? html, String to, String cc, List<MailAttachment> attachments})> fetchBody(
      String id) async {
    final m = await _api.users.messages.get('me', id, format: 'full');
    String header(String name) {
      for (final h in m.payload?.headers ?? <MessagePartHeader>[]) {
        if ((h.name ?? '').toLowerCase() == name) return h.value ?? '';
      }
      return '';
    }

    final plain = _findPart(m.payload, 'text/plain');
    final html = _findPart(m.payload, 'text/html');
    final htmlText = html != null ? _htmlToText(html) : null;
    final String text;
    if (plain != null && plain.trim().isNotEmpty && !_isStubPlain(plain, htmlText)) {
      text = plain;
    } else if (htmlText != null && htmlText.isNotEmpty) {
      // テキスト版がない、または「HTML対応のメーラーでご覧ください」のような案内だけのとき
      text = htmlText;
    } else {
      text = plain ?? _decodeEntities(m.snippet ?? '');
    }
    return (
      text: text,
      html: html,
      to: header('to'),
      cc: header('cc'),
      attachments: _findAttachments(m.payload),
    );
  }

  /// 添付ファイルを探す。ファイル名の付いた「ふつうの添付」だけで、HTMLメールに埋め込まれた画像は除く
  List<MailAttachment> _findAttachments(MessagePart? root) {
    final result = <MailAttachment>[];
    void walk(MessagePart? p) {
      if (p == null) return;
      final name = p.filename ?? '';
      final body = p.body;
      if (name.isNotEmpty && body != null && (body.attachmentId != null || body.data != null)) {
        String h(String n) {
          for (final x in p.headers ?? <MessagePartHeader>[]) {
            if ((x.name ?? '').toLowerCase() == n) return x.value ?? '';
          }
          return '';
        }

        // Content-ID があって「添付」と明示されていないものは、本文に埋め込まれた画像
        final embedded =
            h('content-id').isNotEmpty && !h('content-disposition').toLowerCase().startsWith('attachment');
        if (!embedded) {
          result.add(MailAttachment(
            filename: name,
            mimeType: (p.mimeType ?? '').isEmpty ? 'application/octet-stream' : p.mimeType!,
            size: body.size ?? 0,
            attachmentId: body.attachmentId,
            data: body.data,
          ));
        }
      }
      for (final c in p.parts ?? <MessagePart>[]) {
        walk(c);
      }
    }

    walk(root);
    return result;
  }

  /// 添付ファイルの中身を取り出す
  Future<List<int>> downloadAttachment(String messageId, MailAttachment a) async {
    var data = a.data;
    if (data == null) {
      final body = await _api.users.messages.attachments.get('me', messageId, a.attachmentId!);
      data = body.data ?? '';
    }
    return base64Url.decode(base64Url.normalize(data));
  }

  /// テキスト版が「HTML形式のメールです」のような案内文だけで、中身はHTML版にしかないか
  bool _isStubPlain(String plain, String? htmlText) {
    if (htmlText == null || htmlText.isEmpty) return false;
    final p = plain.trim().length;
    final h = htmlText.length;
    // テキスト版がHTML版の文字に比べて極端に短い
    if (p < 300 && h > p * 2) return true;
    // 「HTML」を含む短めの案内文で、HTML版の方が長い
    if (p < 600 && h > p && RegExp('HTML', caseSensitive: false).hasMatch(plain)) return true;
    return false;
  }

  /// 既読にする（Gmail側の「未読」ラベルを外す）
  Future<void> markRead(String id) async {
    await _api.users.messages.modify(ModifyMessageRequest(removeLabelIds: ['UNREAD']), 'me', id);
  }

  /// ゴミ箱に移動する（30日以内ならGmailから戻せる）
  Future<void> trash(String id) async {
    await _api.users.messages.trash('me', id);
  }

  /// ゴミ箱から戻す
  Future<void> untrash(String id) async {
    await _api.users.messages.untrash('me', id);
  }

  /// 返信を送信する（元メールと同じスレッドに入る）
  /// [to]・[cc] を渡すと、その宛先に送る（全員に返信）。渡さなければ元の送信元だけに送る
  Future<void> sendReply(Mail original, String text, {String? to, String? cc}) async {
    final subject = RegExp(r'^\s*re\s*:', caseSensitive: false).hasMatch(original.subject)
        ? original.subject
        : 'Re: ${original.subject}';
    // 受信メール由来の値なので、<…> の形のIDだけを取り出して使う（改行などで見出しを足されないように。2026-11-18）
    final msgId = _messageIds(original.messageIdHeader ?? '');
    final refs = _messageIds([original.references ?? '', original.messageIdHeader ?? ''].join(' '));

    await _send(
      to: to ?? '${_encodeName(original.senderName)} <${original.senderAddress}>',
      subject: subject,
      text: text,
      extraHeaders: [
        if (cc != null && cc.isNotEmpty) 'Cc: $cc',
        if (msgId.isNotEmpty) 'In-Reply-To: $msgId',
        if (refs.isNotEmpty) 'References: $refs',
      ],
      threadId: original.threadId,
    );
  }

  /// 転送する。[to] はカンマ区切りで複数可。件名は「Fwd: 」付き。[attachments] は一緒に送る元メールの添付
  Future<void> sendForward(Mail original, String to, String text,
      {List<MailAttachment> attachments = const []}) async {
    final subject = RegExp(r'^\s*(fwd?|転送)\s*:', caseSensitive: false).hasMatch(original.subject)
        ? original.subject
        : 'Fwd: ${original.subject}';
    final files = <({String filename, String mimeType, List<int> bytes})>[];
    var total = 0;
    for (final a in attachments) {
      final bytes = await downloadAttachment(original.id, a);
      // 実際にダウンロードした大きさで、Gmailの上限（25MB）を確かめる（2026-11-18 B08）
      total += bytes.length;
      if (total > 25 * 1024 * 1024) {
        throw const AppMessage('添付ファイルの合計が25MBを超えるため送れません。添付を減らしてください');
      }
      files.add((filename: a.filename, mimeType: a.mimeType, bytes: bytes));
    }
    await _send(to: to, subject: subject, text: text, files: files);
  }

  /// 新しいメールを送る。[to] はカンマ区切りで複数可
  Future<void> sendNew(String to, String subject, String text) async {
    await _send(to: to, subject: subject, text: text);
  }

  Future<void> _send({
    required String to,
    required String subject,
    required String text,
    List<String> extraHeaders = const [],
    String? threadId,
    List<({String filename, String mimeType, List<int> bytes})> files = const [],
  }) async {
    // 見出しに改行・制御文字を入れさせない（2026-11-18 セキュリティ対策 A07）
    // 宛先・CC など：入っていたら送らずに止める／件名・ファイル名：空白に置き換えて1行にする
    _checkHeaderValue(to, '宛先');
    for (final h in extraHeaders) {
      _checkHeaderValue(h, h.startsWith('Cc:') ? 'CC' : '返信の情報');
    }
    final common = <String>[
      'To: $to',
      'Subject: ${_encodeHeader(_oneLine(subject))}',
      ...extraHeaders,
      'MIME-Version: 1.0',
    ];
    final textB64 = _wrap76(base64.encode(utf8.encode(text)));

    if (files.isNotEmpty) {
      // 添付あり：本文と添付を multipart/mixed でまとめ、大きくても送れるようアップロードの形で送る
      final boundary = 'fluorine_${DateTime.now().microsecondsSinceEpoch}';
      final sb = StringBuffer()
        ..write([...common, 'Content-Type: multipart/mixed; boundary="$boundary"'].join('\r\n'))
        ..write('\r\n\r\n')
        ..write('--$boundary\r\n')
        ..write('Content-Type: text/plain; charset=UTF-8\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n\r\n')
        ..write('$textB64\r\n');
      for (final f in files) {
        final name = _encodeHeader(_oneLine(f.filename).replaceAll(RegExp(r'["\\]'), ''));
        sb
          ..write('--$boundary\r\n')
          ..write('Content-Type: ${_safeMimeType(f.mimeType)}; name="$name"\r\n')
          ..write('Content-Disposition: attachment; filename="$name"\r\n')
          ..write('Content-Transfer-Encoding: base64\r\n\r\n')
          ..write('${_wrap76(base64.encode(f.bytes))}\r\n');
      }
      sb.write('--$boundary--\r\n');
      final bytes = utf8.encode(sb.toString());
      await _api.users.messages.send(
        Message(threadId: threadId),
        'me',
        uploadMedia: Media(Stream.value(bytes), bytes.length, contentType: 'message/rfc822'),
      );
      return;
    }

    final headers = <String>[
      ...common,
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
    ];
    final raw = '${headers.join('\r\n')}\r\n\r\n$textB64';

    await _api.users.messages.send(
      Message(raw: base64Url.encode(utf8.encode(raw)), threadId: threadId),
      'me',
    );
  }

  /// base64の文字列を76文字ごとに改行する（メールの決まり）
  String _wrap76(String b64) => [
        for (var i = 0; i < b64.length; i += 76) b64.substring(i, i + 76 > b64.length ? b64.length : i + 76),
      ].join('\r\n');

  /// 件名・ファイル名・表示名：改行・タブなどの制御文字を空白にして1行にする
  static String _oneLine(String s) => s.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();

  /// 宛先・CC などに改行・制御文字が入っていたら送らずに止める
  static void _checkHeaderValue(String v, String label) {
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
      throw MailHeaderException('$labelに送れない文字（改行など）が入っています。直してから送ってください');
    }
  }

  /// Message-ID・References から <…> の形のIDだけを取り出す
  static String _messageIds(String s) =>
      RegExp(r'<[^<>\s]+>').allMatches(s).map((m) => m.group(0)).join(' ');

  /// 添付の種類（MIMEタイプ）がおかしな形なら、一般的な「バイナリ」として送る
  static String _safeMimeType(String t) =>
      RegExp(r'^[A-Za-z0-9][\w.+-]*/[\w.+-]+$').hasMatch(t) ? t : 'application/octet-stream';

  /// 日本語などを含むヘッダーをメール用の形式（=?UTF-8?B?...?=）にする
  String _encodeHeader(String s) {
    final ascii = s.codeUnits.every((c) => c < 128);
    if (ascii) return s;
    return '=?UTF-8?B?${base64.encode(utf8.encode(s))}?=';
  }

  String _encodeName(String rawName) {
    final name = _oneLine(rawName);
    if (name.isEmpty || name.contains('@')) return '';
    final ascii = name.codeUnits.every((c) => c < 128);
    return ascii ? '"${name.replaceAll('"', '')}"' : _encodeHeader(name);
  }

  Mail _toMail(Message m) {
    final headers = m.payload?.headers ?? <MessagePartHeader>[];
    String header(String name) {
      for (final h in headers) {
        if ((h.name ?? '').toLowerCase() == name) return h.value ?? '';
      }
      return '';
    }

    final (name, address) = _parseFrom(header('from'));
    final ms = int.tryParse(m.internalDate ?? '') ?? 0;
    final subject = header('subject');
    return Mail(
      id: m.id ?? '',
      senderName: name,
      senderAddress: address,
      subject: subject.isEmpty ? '（件名なし）' : subject,
      body: _decodeEntities(m.snippet ?? ''),
      bodyLoaded: false,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      isRead: !(m.labelIds ?? const []).contains('UNREAD'),
      threadId: m.threadId,
      messageIdHeader: header('message-id').isEmpty ? null : header('message-id'),
      references: header('references').isEmpty ? null : header('references'),
      toHeader: header('to'),
      ccHeader: header('cc'),
    );
  }

  /// 「山田 太郎 <taro@example.com>」→（山田 太郎, taro@example.com）
  (String, String) _parseFrom(String from) {
    final match = RegExp(r'^\s*"?(.*?)"?\s*<([^>]+)>\s*$').firstMatch(from);
    if (match != null) {
      final addr = match.group(2)!.trim().toLowerCase();
      final name = match.group(1)!.trim();
      return (name.isEmpty ? addr : name, addr);
    }
    final addr = from.trim().toLowerCase();
    return (addr, addr);
  }

  String? _findPart(MessagePart? part, String mime) {
    if (part == null) return null;
    if (part.mimeType == mime && part.body?.data != null && (part.filename ?? '').isEmpty) {
      return _decodeBase64(part.body!.data!);
    }
    for (final p in part.parts ?? <MessagePart>[]) {
      final found = _findPart(p, mime);
      if (found != null) return found;
    }
    return null;
  }

  String _decodeBase64(String data) =>
      utf8.decode(base64Url.decode(base64Url.normalize(data)), allowMalformed: true);

  /// HTMLから読める文字だけを取り出す（AIに渡す本文・引用に使う）
  String _htmlToText(String html) {
    var s = html
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
        .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<(style|script|title)[^>]*>[\s\S]*?</\1>', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\r\n]+'), ' ') // HTMLの改行は表示上の改行ではない
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|tr|li|h\d|table|blockquote)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(td|th)>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    s = _decodeEntities(s);
    s = s
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t\u00A0\u3000]+'), ' ').trim())
        .join('\n');
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  String _decodeEntities(String s) => s
      .replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'),
          (m) => _charOf(int.tryParse(m[1]!, radix: 16)) ?? m[0]!)
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => _charOf(int.tryParse(m[1]!)) ?? m[0]!)
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&yen;', '¥')
      .replaceAll('&copy;', '©')
      .replaceAll('&reg;', '®')
      .replaceAll('&hellip;', '…')
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&rarr;', '→')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  String? _charOf(int? code) {
    if (code == null || code <= 0 || code > 0x10FFFF) return null;
    return String.fromCharCode(code);
  }
}

/// メールの見出しに送れない文字があったときのエラー（2026-11-18）
class MailHeaderException extends AppMessage {
  const MailHeaderException(super.message);
}
