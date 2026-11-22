import 'models.dart';

/// メールアドレス1件（名前とアドレス）
typedef MailAddress = ({String name, String address});

/// 「`山田 太郎 <taro@example.com>`」→（山田 太郎, taro@example.com）。アドレスでなければ null
MailAddress? parseAddress(String s) {
  final m = RegExp(r'^\s*"?(.*?)"?\s*<([^>]+)>\s*$').firstMatch(s);
  if (m != null) return (name: m.group(1)!.trim(), address: m.group(2)!.trim().toLowerCase());
  final a = s.trim().toLowerCase();
  return a.contains('@') ? (name: '', address: a) : null;
}

/// To・Cc ヘッダー（カンマ区切りで複数）を1件ずつに分ける。名前の中のカンマ（"山田, 太郎"）では分けない
List<MailAddress> parseAddressList(String header) {
  final result = <MailAddress>[];
  final buf = StringBuffer();
  var inQuote = false;
  var inAngle = false;
  void flush() {
    final one = buf.toString().trim();
    buf.clear();
    if (one.isEmpty) return;
    final p = parseAddress(one);
    if (p != null) result.add(p);
  }

  for (final ch in header.split('')) {
    if (ch == '"') {
      inQuote = !inQuote;
    } else if (ch == '<' && !inQuote) {
      inAngle = true;
    } else if (ch == '>' && !inQuote) {
      inAngle = false;
    }
    if ((ch == ',' || ch == ';') && !inQuote && !inAngle) {
      flush();
      continue;
    }
    buf.write(ch);
  }
  flush();
  return result;
}

/// 「全員に返信」の宛先とCC（Gmailと同じ考え方）
/// - 宛先：元の送信元＋元の宛先の人
/// - CC：元のCCの人
/// 自分のアドレス [me] と、重なっているアドレスは除く
({List<String> to, List<String> cc}) replyAllRecipients(Mail mail, String? me) {
  final seen = <String>{if (me != null && me.isNotEmpty) me.toLowerCase()};
  final to = <String>[];
  final cc = <String>[];
  void add(List<String> list, String a) {
    if (a.isNotEmpty && seen.add(a)) list.add(a);
  }

  add(to, mail.senderAddress.toLowerCase());
  for (final p in parseAddressList(mail.toHeader)) {
    add(to, p.address);
  }
  for (final p in parseAddressList(mail.ccHeader)) {
    add(cc, p.address);
  }
  // 自分が送ったメール（送信元も宛先も自分など）で宛先が空になったときは、Gmailと同じく自分を宛先に残す
  if (to.isEmpty && cc.isNotEmpty && me != null && me.isNotEmpty) to.add(me.toLowerCase());
  return (to: to, cc: cc);
}

/// 「全員に返信」を出すか：ふつうの返信（元の送信元だけに送る）と比べて、ほかにも相手がいるか
/// 自分が送ったメール（送信元が自分）でも、宛先・CCに自分以外がいれば出す
bool hasOtherRecipients(Mail mail, String? me) {
  final mine = me?.toLowerCase();
  final sender = mail.senderAddress.toLowerCase();
  final others = {
    for (final p in [...parseAddressList(mail.toHeader), ...parseAddressList(mail.ccHeader)]) p.address,
  }..removeWhere((a) => a == mine || a == sender);
  return others.isNotEmpty;
}
