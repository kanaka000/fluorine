/// メール1通
class Mail {
  Mail({
    required this.id,
    required this.senderName,
    required this.senderAddress,
    required this.subject,
    required this.body,
    required this.receivedAt,
    this.isRead = false,
    this.bodyLoaded = true,
    this.threadId,
    this.messageIdHeader,
    this.references,
    this.toHeader = '',
    this.ccHeader = '',
  });

  final String id;
  final String senderName;
  final String senderAddress;
  final String subject;
  /// 本文（Gmailから取得した直後は概要だけ。開いたときに全文に置き換える）
  String body;

  /// HTML版の本文（あれば。開いたときに取得）
  String? html;
  final DateTime receivedAt;
  bool isRead;
  bool bodyLoaded;

  /// 返信に使う情報（Gmailのメールのみ）
  final String? threadId;
  final String? messageIdHeader; // 元メールの Message-ID
  final String? references; // 元メールの References

  /// 元メールの宛先（To）とCC（全員に返信に使う。ヘッダーそのままの文字）
  String toHeader;
  String ccHeader;

  /// 添付ファイル（本文を開いたときに取得。メール内に埋め込まれた画像は含まない）
  List<MailAttachment> attachments = const [];
}

/// 添付ファイル1つ（中身は転送するときに取り出す）
class MailAttachment {
  MailAttachment({
    required this.filename,
    required this.mimeType,
    required this.size,
    this.attachmentId,
    this.data,
  });

  final String filename;
  final String mimeType;

  /// 大きさ（バイト）
  final int size;

  /// Gmailの添付ID（中身はこれで取り出す）
  final String? attachmentId;

  /// 小さい添付は、本文と一緒に中身が届いていることがある（base64url）
  final String? data;

  /// 「230KB」「1.2MB」のような表示
  String get sizeText => formatBytes(size);
}

/// バイト数を「230KB」「1.2MB」のように表示する
String formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// 送信元ごとに束ねたメール（mails は新しい順）
class SenderGroup {
  SenderGroup({
    required this.address,
    required this.name,
    required this.mails,
    List<String>? addresses,
  }) : addresses = addresses ?? [address];

  /// この行の代表のアドレス（まとめたときは、まとめ先＝最初に開いた送信元）
  final String address;

  /// この行に入っているアドレス全部（手動でまとめたときは複数）
  final List<String> addresses;

  bool get merged => addresses.length > 1;
  final String name;
  final List<Mail> mails;

  Mail get latest => mails.first;
  int get unreadCount => mails.where((m) => !m.isRead).length;
  int get readCount => mails.length - unreadCount;
  bool get hasUnread => unreadCount > 0;
}
