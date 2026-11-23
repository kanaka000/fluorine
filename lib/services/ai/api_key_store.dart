import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../errors.dart';

// AnthropicのAPIキーを、アプリの中で入れて暗号化して保存する（2026-11-23）。
// 以前はビルドのときに secrets.json から組み込んでいたので、キーを替えるたびにビルドし直しだった。
// ・キーは Android の Keystore で暗号化して保存する（flutter_secure_storage の初期の方式）
// ・組み込まれたキーがあれば、最初の起動で1回だけここへ移す（移したあとは組み込まれたキーを使わない）
// ・保存の前に、料金のかからない問い合わせ（モデル一覧）でキーが通るか確かめる

/// ビルドのときに組み込まれたキー（移行用。新しいビルドでは空でよい）
const _builtInKey = String.fromEnvironment('ANTHROPIC_API_KEY');

/// 組み込まれたキーの期限（移行用。2026-11-23 の21で足した）
const _builtInExpires = String.fromEnvironment('ANTHROPIC_API_KEY_EXPIRES');

const _storage = FlutterSecureStorage();
const _keyName = 'anthropic_api_key';

/// 空白・見本のまま（「ここに」を含む）のキーは、ないものとして扱う
bool _usable(String? k) => k != null && k.trim().isNotEmpty && !k.contains('ここに');

/// 期限の日付を読む（YYYY-MM-DD か YYYY/MM/DD。空・見本のまま・読めなければ null）
DateTime? parseKeyExpiry(String text) {
  final m = RegExp(r'^\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(text);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return DateTime(y, mo, d);
}

/// キーが通るかの結果
enum KeyCheck { ok, invalid, unknown }

/// キーが通るか確かめる（モデル一覧の問い合わせ。トークンを使わないので料金はかからない）
Future<KeyCheck> checkApiKey(String key) async {
  try {
    final res = await http.get(
      Uri.parse('https://api.anthropic.com/v1/models?limit=1'),
      headers: {'x-api-key': key.trim(), 'anthropic-version': '2023-06-01'},
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode == 200) return KeyCheck.ok;
    devLog('APIキーの確認（${res.statusCode}）：${res.body}');
    return (res.statusCode == 401 || res.statusCode == 403) ? KeyCheck.invalid : KeyCheck.unknown;
  } catch (e) {
    devLog('APIキーの確認に失敗：$e');
    return KeyCheck.unknown;
  }
}

final apiKeyStore = ApiKeyStore();

class ApiKeyStore extends ChangeNotifier {
  SharedPreferences? _prefs;
  String? _key;

  /// キーの期限（null＝期限なし・分からない）
  DateTime? expiry;

  /// 使っている途中でキーが使えなかった（401など）。入れ直すまで印を付けておく
  bool invalid = false;

  /// 使えるキーがあるか
  bool get available => _usable(_key);

  /// 送るときのキー
  String get key => (_key ?? '').trim();

  /// 画面に出す形（最後の4文字だけ）
  String get masked {
    final k = key;
    if (k.isEmpty) return '';
    return 'sk-ant-…${k.length > 4 ? k.substring(k.length - 4) : ''}';
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    try {
      _key = await _storage.read(key: _keyName);
    } catch (e) {
      // 暗号の鍵が読めない（端末の移行など）ときは、入れ直してもらう
      devLog('APIキーを読めませんでした：$e');
      _key = null;
      try {
        await _storage.delete(key: _keyName);
      } catch (_) {}
    }
    final exp = p.getString('apiKeyExpires');
    expiry = exp == null ? null : parseKeyExpiry(exp);
    invalid = p.getBool('apiKeyInvalid') ?? false;
    // 組み込まれたキーを1回だけ移す（移したあと、またはキーを消したあとは移さない）
    if (!_usable(_key) && _usable(_builtInKey) && p.getBool('apiKeyMoved') != true) {
      try {
        await _storage.write(key: _keyName, value: _builtInKey.trim());
        _key = _builtInKey.trim();
        expiry = parseKeyExpiry(_builtInExpires);
        _saveExpiry();
        await p.setBool('apiKeyMoved', true);
        devLog('組み込まれたAPIキーを、暗号化して保存しました');
      } catch (e) {
        devLog('組み込まれたAPIキーを移せませんでした：$e');
      }
    }
    notifyListeners();
  }

  void _saveExpiry() {
    final e = expiry;
    if (e == null) {
      _prefs?.remove('apiKeyExpires');
    } else {
      _prefs?.setString('apiKeyExpires', '${e.year}-${e.month}-${e.day}');
    }
  }

  /// 新しいキーを保存する（確かめるのは画面の側で先に行う）。保存したらクリップボードも空にする
  Future<void> save(String newKey, DateTime? newExpiry) async {
    await _storage.write(key: _keyName, value: newKey.trim());
    _key = newKey.trim();
    expiry = newExpiry;
    _saveExpiry();
    invalid = false;
    await _prefs?.setBool('apiKeyInvalid', false);
    await _prefs?.setBool('apiKeyMoved', true);
    await Clipboard.setData(const ClipboardData(text: ''));
    notifyListeners();
  }

  /// キーを消す（組み込まれたキーも、もう移さない）
  Future<void> delete() async {
    try {
      await _storage.delete(key: _keyName);
    } catch (e) {
      devLog('APIキーを消せませんでした：$e');
    }
    _key = null;
    expiry = null;
    _saveExpiry();
    invalid = false;
    await _prefs?.setBool('apiKeyInvalid', false);
    await _prefs?.setBool('apiKeyMoved', true);
    notifyListeners();
  }

  /// 使っている途中でキーが使えなかったとき（401・403）
  void markInvalid() {
    if (invalid) return;
    invalid = true;
    _prefs?.setBool('apiKeyInvalid', true);
    notifyListeners();
  }

  /// 使えたとき（入れ直さずに戻った場合も印を外す）
  void markValid() {
    if (!invalid) return;
    invalid = false;
    _prefs?.setBool('apiKeyInvalid', false);
    notifyListeners();
  }

  /// 「端末内のデータを消す」のあと（SharedPreferences.clear のあとに呼ぶ）。キーも消す
  Future<void> clearLocal() async {
    await delete();
  }
}
