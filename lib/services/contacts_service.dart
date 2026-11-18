import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  const ContactSearchResult(this.list, {this.problem});
  final List<ContactCandidate> list;
  final String? problem;
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
        if (!_warmedUp) {
          // People API は、最初に空の検索をしてから探す決まり（内部の準備のため）
          await Future.wait([
            _get('people:searchContacts', '', headers),
            _get('otherContacts:search', '', headers),
          ]);
          _warmedUp = true;
        }
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

  /// 連絡先を読むための認証ヘッダー。まだ許可していなければ許可画面を出す（断られたら null）
  static Future<Map<String, String>?> _headers() async {
    final u = googleAuth.user;
    if (u == null) return null;
    return u.authorizationClient.authorizationHeaders(contactScopes, promptIfNecessary: true);
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
