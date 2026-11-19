import 'package:flutter/foundation.dart';

import '../services/gmail_service.dart';
import '../services/google_auth.dart';
import 'models.dart';
import 'sender_merges.dart';
import '../services/errors.dart';

/// アプリ全体で使うメールの保管場所
/// ログイン後はGmailの受信トレイを表示する（ログアウト中は空。2026-11-16 ダミーデータをやめた）
final mailStore = MailStore([]);

class MailStore extends ChangeNotifier {
  MailStore(this._mails) {
    // 送信元のまとめが変わったら、一覧を描き直す
    senderMerges.addListener(notifyListeners);
  }

  final List<Mail> _mails;
  GmailService? _gmail;

  bool loading = false;
  String? error;
  DateTime? lastLoaded;

  /// 前回の読み込み時点の履歴ID（次回はここから後の変更だけを取る）
  String? _historyId;

  /// 差分で取るのはこの件数まで。これより多く変わっていたら全部読み込み直す
  static const _maxChanges = 150;

  /// Gmailのデータを表示しているか（false ならダミー）
  bool get usingGmail => _gmail != null;

  /// 新しい順のメール（AIに渡す参考情報用）。[limit] 通まで
  List<Mail> recentMails(int limit) {
    final list = [..._mails]..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return list.take(limit).toList();
  }

  /// 送信元（メールアドレス）ごとに束ね、最新メールが新しい順に並べる。
  /// 手動でまとめた送信元は、まとめ先の行に入れる
  List<SenderGroup> get groups {
    final map = <String, List<Mail>>{};
    for (final m in _mails) {
      map.putIfAbsent(senderMerges.primaryOf(m.senderAddress), () => []).add(m);
    }
    final result = map.entries.map((e) {
      final list = [...e.value]
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      // 名前は、まとめ先（最初に開いた送信元）のメールの名前を使う
      final own = list.where((m) => m.senderAddress == e.key);
      final name = own.isNotEmpty ? own.first.senderName : list.first.senderName;
      final addresses = {for (final m in list) m.senderAddress}.toList();
      return SenderGroup(address: e.key, name: name, mails: list, addresses: addresses);
    }).toList()
      ..sort((a, b) => b.latest.receivedAt.compareTo(a.latest.receivedAt));
    return result;
  }

  SenderGroup? groupOf(String address) {
    for (final g in groups) {
      if (g.address == address) return g;
    }
    return null;
  }

  /// Gmailから読み込む。prompt=true はボタン操作のときだけ（許可画面を出せる）。
  /// 2回目からは、前回から変わったメールだけを取る（差分取得）。full=true なら全部読み込み直す
  Future<void> reload({bool prompt = false, bool full = false}) async {
    if (!googleAuth.signedIn || loading) return;
    final gen = googleAuth.session; // 途中でログアウトしたら結果を捨てる（2026-11-18）
    loading = true;
    error = null;
    notifyListeners();
    try {
      final client = await googleAuth.authorizedClient(prompt: prompt);
      googleAuth.checkSession(gen);
      if (client == null) {
        error = 'Gmailへのアクセスがまだ許可されていません';
      } else {
        final gmail = GmailService(client);
        final canDiff = !full && _gmail != null && _historyId != null;
        if (!(canDiff && await _applyChanges(gmail, gen))) {
          // 初回・履歴が古すぎる・変更が多すぎるときは、受信トレイを全部読み込み直す
          final historyId = await gmail.currentHistoryId(); // 先に取っておき、読み込み中の変更も次回拾う
          final mails = await gmail.fetchInbox();
          googleAuth.checkSession(gen);
          _mails
            ..clear()
            ..addAll(mails);
          _historyId = historyId;
        }
        _gmail = gmail;
        lastLoaded = DateTime.now();
      }
    } on StaleSession {
      // ログアウト・アカウントの切り替えの前に始めた読み込み → 結果は捨てる
    } catch (e) {
      if (gen == googleAuth.session) error = '読み込みに失敗しました：${friendlyError(e)}';
    } finally {
      if (gen == googleAuth.session) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 前回から変わったメールだけを反映する。全部読み込み直すべきときは false
  Future<bool> _applyChanges(GmailService gmail, int gen) async {
    final res = await gmail.changesSince(_historyId!);
    googleAuth.checkSession(gen);
    if (res == null || res.changed.length > _maxChanges) return false;
    final ids = res.changed.toList();
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.skip(i).take(10).toList();
      final states = await Future.wait(chunk.map(gmail.fetchState));
      googleAuth.checkSession(gen);
      for (var j = 0; j < chunk.length; j++) {
        final id = chunk[j];
        final state = states[j];
        final index = _mails.indexWhere((m) => m.id == id);
        if (state.mail == null) {
          // 削除・アーカイブ・ゴミ箱へ移動されたメールは一覧から消す
          if (index >= 0) _mails.removeAt(index);
        } else if (index >= 0) {
          // すでにあるメールは、既読／未読だけ更新（取得済みの本文はそのまま）
          _mails[index].isRead = state.mail!.isRead;
        } else {
          _mails.add(state.mail!); // 新着
        }
      }
    }
    _historyId = res.historyId ?? _historyId;
    return true;
  }

  /// 前回の読み込みから一定時間たっていれば読み込み直す（自動読み込み用）
  Future<void> reloadIfStale({Duration maxAge = const Duration(seconds: 60)}) async {
    final last = lastLoaded;
    if (last != null && DateTime.now().difference(last) < maxAge) return;
    await reload();
  }

  /// 自動読み込みがオフのとき：ダミーを消して、手動で読み込むまで空にする
  void clearForManual() {
    if (_gmail != null) return;
    _mails.clear();
    notifyListeners();
  }

  /// ログアウト時：空にする
  void resetForSignOut() {
    loading = false; // 読み込み中でも、ログインし直したらすぐ読み込めるように
    _gmail = null;
    _historyId = null;
    _byId.clear();
    lastLoaded = null;
    error = null;
    _mails.clear();
    notifyListeners();
  }

  /// リンクから開くメール（受信トレイにないものも）を覚えておく。null＝見つからない（2026-11-19）
  final Map<String, Mail?> _byId = {};

  /// 読み込み済みのメールから探す（なければ null）
  Mail? loadedMail(String id) {
    for (final m in _mails) {
      if (m.id == id) return m;
    }
    return _byId[id];
  }

  /// IDでメールを探す。読み込み済みになければ Gmail から1通読む。完全に消えていれば null。
  /// ログアウト中・通信の失敗は例外
  Future<Mail?> mailById(String id) async {
    final m = loadedMail(id);
    if (m != null || _byId.containsKey(id)) return m;
    final gmail = _gmail;
    if (gmail == null) throw const AppMessage('Googleにログインしてください');
    final found = await gmail.fetchById(id);
    _byId[id] = found;
    return found;
  }

  /// メールを探す（✨の「メールを探して」。2026-11-19）。
  /// 受信トレイの一覧にあるメールは同じものを使う（既読などがそろうように）
  Future<List<Mail>> searchMails(String query) async {
    final gmail = _gmail;
    if (gmail == null) throw const AppMessage('Googleにログインしてください');
    final gen = googleAuth.session;
    final found = await gmail.search(query);
    if (gen != googleAuth.session) throw const AppMessage('ログアウトしたため中止しました');
    return [
      for (final m in found)
        if (loadedMail(m.id) case final known?)
          (known.bodyLoaded || known.attachments.isNotEmpty ? known : (known..attachments = m.attachments))
        else
          m,
    ];
  }

  /// 添付ファイルの中身を読み込む（外部アプリで開くため。2026-11-19）
  Future<List<int>> downloadAttachment(Mail mail, MailAttachment a) async {
    final gmail = _gmail;
    if (gmail == null) throw const AppMessage('Googleにログインしてください');
    final gen = googleAuth.session;
    final bytes = await gmail.downloadAttachment(mail.id, a);
    if (gen != googleAuth.session) throw const AppMessage('ログアウトしたため中止しました');
    return bytes;
  }

  /// 本文の全文がまだなら取得する
  Future<void> ensureBody(Mail mail) async {
    final gmail = _gmail;
    if (mail.bodyLoaded || gmail == null) return;
    final gen = googleAuth.session;
    try {
      final b = await gmail.fetchBody(mail.id);
      if (gen != googleAuth.session) return; // 途中でログアウトした
      mail.body = b.text;
      mail.html = b.html;
      if (b.to.isNotEmpty) mail.toHeader = b.to;
      if (b.cc.isNotEmpty) mail.ccHeader = b.cc;
      mail.attachments = b.attachments;
      mail.bodyLoaded = true;
      notifyListeners();
    } catch (e) {
      devLog('本文の取得に失敗: $e');
    }
  }

  /// メールを削除（ゴミ箱に移動）する。画面からはすぐに消す
  Future<void> trash(Mail mail) async {
    _mails.remove(mail);
    notifyListeners();
    try {
      await _gmail?.trash(mail.id);
    } catch (e) {
      _mails.add(mail); // 失敗したら元に戻す
      error = '削除に失敗しました：${friendlyError(e)}';
      notifyListeners();
    }
  }

  /// 削除の取り消し（ゴミ箱から戻す）
  Future<void> untrash(Mail mail) async {
    if (!_mails.contains(mail)) _mails.add(mail);
    notifyListeners();
    try {
      await _gmail?.untrash(mail.id);
    } catch (e) {
      error = '元に戻せませんでした：${friendlyError(e)}';
      notifyListeners();
    }
  }

  /// 返信を送信する（ダミー表示中は送信しない）。失敗すると例外
  /// [to]・[cc] を渡すと全員に返信（カンマ区切り）
  Future<void> sendReply(Mail original, String text, {String? to, String? cc}) async {
    final gmail = _gmail;
    if (gmail == null) return;
    await gmail.sendReply(original, text, to: to, cc: cc);
  }

  /// 新しいメールを送る（ダミー表示中は送信しない）。失敗すると例外
  Future<void> sendNew(String to, String subject, String text) async {
    final gmail = _gmail;
    if (gmail == null) return;
    await gmail.sendNew(to, subject, text);
  }

  /// 転送する（ダミー表示中は送信しない）。失敗すると例外
  Future<void> sendForward(Mail original, String to, String text,
      {List<MailAttachment> attachments = const []}) async {
    final gmail = _gmail;
    if (gmail == null) return;
    await gmail.sendForward(original, to, text, attachments: attachments);
  }

  void markRead(Mail mail) {
    if (!mail.isRead) {
      mail.isRead = true;
      notifyListeners();
      _gmail?.markRead(mail.id).catchError((Object e) => devLog('既読化に失敗: $e'));
    }
  }
}
