import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/errors.dart';

/// 送信元の手動統合（端末に保存され、次回起動時も引き継がれる）
///
/// まとめた送信元のアドレス → まとめ先（最初に開いた送信元）のアドレス、の対応を持つ
/// Googleアカウントごとに分けて保存する（2026-11-18。別のアカウントでログインしたら使わない）
final senderMerges = SenderMerges();

class SenderMerges extends ChangeNotifier {
  /// 以前の保存先（アカウントで分けていなかった）。最初にログインしたアカウントのものとして移す
  static const _legacyKey = 'senderMerges';
  static String _keyOf(String account) => 'senderMerges:$account';

  SharedPreferences? _prefs;
  final Map<String, String> _aliasTo = {};

  /// 今のアカウント（ログアウト中は null）
  String? _account;
  bool _accountSet = false;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// ログイン中のアカウントが変わったら呼ぶ（main.dart で googleAuth につないでいる）
  void setAccount(String? email) {
    final account = email?.trim().toLowerCase();
    if (_accountSet && account == _account) return;
    _accountSet = true;
    _account = account;
    _aliasTo.clear();
    final p = _prefs;
    if (p != null && account != null && account.isNotEmpty) {
      var raw = p.getString(_keyOf(account));
      final legacy = p.getString(_legacyKey);
      if (raw == null && legacy != null) {
        raw = legacy;
        p.setString(_keyOf(account), legacy);
        p.remove(_legacyKey);
      }
      if (raw != null) {
        try {
          _aliasTo.addAll((jsonDecode(raw) as Map).cast<String, String>());
        } catch (e) {
          devLog('送信元のまとめの読み込みに失敗: $e');
        }
      }
    }
    notifyListeners();
  }

  /// 「端末内のデータを消す」のあと（保存した分は消してあるので、画面の分だけ空にする）
  void clearLocal() {
    _aliasTo.clear();
    notifyListeners();
  }

  void _save() {
    final a = _account;
    if (a != null && a.isNotEmpty) _prefs?.setString(_keyOf(a), jsonEncode(_aliasTo));
    notifyListeners();
  }

  /// このアドレスのメールを、どの送信元の行に入れるか
  String primaryOf(String address) => _aliasTo[address] ?? address;

  /// [primary] の行に [others] をまとめる（others がすでに別のまとめ先なら、その中身ごと移す）
  void merge(String primary, Iterable<String> others) {
    final target = primaryOf(primary);
    for (final other in others) {
      final o = primaryOf(other);
      if (o == target) continue;
      // o にまとめられていたアドレスも、まとめて移す
      for (final k in _aliasTo.keys.toList()) {
        if (_aliasTo[k] == o) _aliasTo[k] = target;
      }
      _aliasTo[o] = target;
    }
    _save();
  }

  /// 今の状態の控え（「元に戻す」用）
  Map<String, String> snapshot() => Map.of(_aliasTo);

  /// 控えの状態に戻す
  void restore(Map<String, String> saved) {
    _aliasTo
      ..clear()
      ..addAll(saved);
    _save();
  }

  /// [primary] にまとめたものを全部解除する
  void unmerge(String primary) {
    _aliasTo.removeWhere((_, v) => v == primary);
    _save();
  }
}
