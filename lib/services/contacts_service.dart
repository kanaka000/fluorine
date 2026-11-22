import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/mail_store.dart';
import 'google_auth.dart';
import 'errors.dart';

/// 連絡先を読む権限（AIボタンで「○○さんにメール」を頼んだときに、初めて許可を求める）
/// - contacts.readonly：自分で登録した連絡先
/// - contacts.other.readonly：その他の連絡先（やり取りしたことのある相手。Gmailの宛先候補と同じ）
const contactScopes = <String>[
  'https://www.googleapis.com/auth/contacts.readonly',
  'https://www.googleapis.com/auth/contacts.other.readonly',
];

/// 宛先の候補1件
class ContactCandidate {
  const ContactCandidate({required this.name, required this.address, required this.source});
  final String name;
  final String address;

  /// どこで見つけたか（連絡先／その他の連絡先／受信メール）
  final String source;
}

/// 探した結果。[problem] は連絡先を読めなかったときの理由（受信メールからは探している）
class ContactSearchResult {
  const ContactSearchResult(this.list, {this.problem, this.noPermission = false});
  final List<ContactCandidate> list;
  final String? problem;

  /// 連絡先を読む許可がまだない（宛先の欄の候補で、許可画面を出さずに探したとき。2026-11-22）
  final bool noPermission;
}

/// 名前からメールアドレスを探す（Googleの連絡先 → その他の連絡先 → 受信メールの送信元）
class ContactsService {
  static bool _warmedUp = false;

  /// 「田中さん」→「田中」のように敬称を外す
  static String cleanName(String name) =>
      name.trim().replaceAll(RegExp(r'\s*(さん|さま|様|くん|君|ちゃん|殿|氏)$'), '').trim();

  static Future<ContactSearchResult> search(String rawName) async {
    final name = cleanName(rawName);
    if (name.isEmpty) return const ContactSearchResult([]);
    final found = <ContactCandidate>[];
    String? problem;
    try {
      final headers = await _headers();
      if (headers == null) {
        problem = '連絡先を読む許可がないため、受信メールの送信元から探しました';
      } else {
        await _warmUp(headers);
        final results = await Future.wait([
          _get('people:searchContacts', name, headers),
          _get('otherContacts:search', name, headers),
        ]);
        found
          ..addAll(_parse(results[0], '連絡先'))
          ..addAll(_parse(results[1], 'その他の連絡先'));
      }
    } catch (e) {
      devLog('連絡先の検索に失敗: $e');
      problem = '連絡先を読めませんでした（$e）。受信メールの送信元から探しました';
    }
    found.addAll(_fromMails(name));

    // 同じアドレスは1つにまとめる（先に見つけたほうを残す）
    final seen = <String>{};
    final list = [for (final c in found) if (seen.add(c.address.toLowerCase())) c];
    return ContactSearchResult(list, problem: problem);
  }

  /// 宛先の欄の候補用（2026-11-22）：Googleの連絡先・その他の連絡先だけを探す。
  /// まだ許可していなければ許可画面は出さず、noPermission を返す。失敗は空（打っている途中なので知らせない）
  static Future<ContactSearchResult> searchContacts(String rawQuery) async {
    final q = cleanName(rawQuery);
    if (q.isEmpty) return const ContactSearchResult([]);
    try {
      final headers = await _headers(prompt: false);
      if (headers == null) return const ContactSearchResult([], noPermission: true);
      await _warmUp(headers);
      final results = await Future.wait([
        _get('people:searchContacts', q, headers),
        _get('otherContacts:search', q, headers),
      ]);
      return ContactSearchResult([..._parse(results[0], '連絡先'), ..._parse(results[1], 'その他の連絡先')]);
    } catch (e) {
      devLog('連絡先の候補の検索に失敗: $e');
      return const ContactSearchResult([]);
    }
  }

  /// 連絡先を読む許可を求める（宛先の欄の「Googleの連絡先も探す」。2026-11-22）。許可されたら true
  static Future<bool> requestPermission() async {
    try {
      return await _headers() != null;
    } catch (e) {
      devLog('連絡先の許可に失敗: $e');
      return false;
    }
  }

  /// 受信メールの送信元から候補を探す（通信なし。宛先の欄の候補用）
  static List<ContactCandidate> fromMails(String query) {
    final q = cleanName(query);
    return q.isEmpty ? const [] : _fromMails(q);
  }

  /// People API は、最初に空の検索をしてから探す決まり（内部の準備のため）
  static Future<void> _warmUp(Map<String, String> headers) async {
    if (_warmedUp) return;
    await Future.wait([
      _get('people:searchContacts', '', headers),
      _get('otherContacts:search', '', headers),
    ]);
    _warmedUp = true;
  }

  /// 連絡先を読むための認証ヘッダー。[prompt] なら、まだ許可していなければ許可画面を出す（断られたら null）
  static Future<Map<String, String>?> _headers({bool prompt = true}) async {
    final u = googleAuth.user;
    if (u == null) return null;
    return u.authorizationClient.authorizationHeaders(contactScopes, promptIfNecessary: prompt);
  }

  static Future<Map<String, dynamic>> _get(String path, String query, Map<String, String> headers) async {
    final uri = Uri.https('people.googleapis.com', '/v1/$path', {
      'query': query,
      'readMask': 'names,emailAddresses',
      'pageSize': '15',
    });
    final res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 30)); // 2026-11-18 B08
    final body = utf8.decode(res.bodyBytes);
    if (res.statusCode == 403 && body.contains('SERVICE_DISABLED')) {
      throw const AppMessage('Google Cloud で People API が有効になっていません');
    }
    if (res.statusCode != 200) throw AppMessage('連絡先を読めませんでした（${res.statusCode}）');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static List<ContactCandidate> _parse(Map<String, dynamic> json, String source) {
    final out = <ContactCandidate>[];
    for (final r in (json['results'] as List? ?? const [])) {
      final person = ((r as Map)['person'] as Map?) ?? const {};
      final names = person['names'] as List? ?? const [];
      final displayName = names.isEmpty ? '' : ((names.first as Map)['displayName'] as String? ?? '');
      for (final e in (person['emailAddresses'] as List? ?? const [])) {
        final address = ((e as Map)['value'] as String? ?? '').trim();
        if (address.isNotEmpty) {
          out.add(ContactCandidate(name: displayName.isEmpty ? address : displayName, address: address, source: source));
        }
      }
    }
    return out;
  }

  /// 受信メールの送信元から、名前（またはアドレス）に [name] を含む人を探す
  static List<ContactCandidate> _fromMails(String name) {
    String norm(String s) => s.replaceAll(RegExp(r'\s'), '').toLowerCase();
    final q = norm(name);
    final out = <ContactCandidate>[];
    for (final g in mailStore.groups) {
      for (final m in g.mails) {
        if (norm(m.senderName).contains(q) || m.senderAddress.toLowerCase().contains(q)) {
          out.add(ContactCandidate(name: m.senderName, address: m.senderAddress, source: '受信メール'));
          break; // 同じグループは1件でよい
        }
      }
    }
    return out;
  }
}
