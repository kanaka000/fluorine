/// 予定・タスクにつないだメモ（メモのリンク。2026-11-19）
///
/// Googleの予定・タスクのメモ欄（description／notes）の最後に、1つにつき1行
/// `📝 メモ：タイトル〔memo:<メモID>〕` を足して保存する。Google側に残るので、
/// アプリを入れ直してもリンクは消えない。アプリの中ではこの行を隠して、カードで見せる。
class MemoLinkRef {
  const MemoLinkRef(this.id, this.title);

  /// メモのID（Memo.id）
  final String id;

  /// 保存したときのメモのタイトル（IDで見つからないときの手がかり）
  final String title;
}

/// 予定・タスクにつないだメール（メールのリンク。2026-11-19）。
/// メモ欄の最後の1行 `✉️ メール：件名〔mail:<GmailのメッセージID>〕` で保存する
class MailLinkRef {
  const MailLinkRef(this.id, this.subject);

  /// Gmail のメッセージID（Mail.id）
  final String id;

  /// 保存したときの件名（メールが見つからないときに見せる）
  final String subject;
}
