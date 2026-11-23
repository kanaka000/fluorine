import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../util/date_text.dart';
import 'api_key_store.dart';

// APIキーの期限・今月の使用額の目安・最後のエラー（2026-11-23 の21）。
// ふつうのAPIキーでは、期限も使用額も Anthropic から読めない。そこで
// ・期限は、キーを入れるときに選んだ日付（apiKeyStore.expiry）から計算する
// ・使用額は、応答に付くトークン数（usage）をアプリが月ごとに足して、料金の表から目安を出す
// ・期限切れ・上限到達は、エラーの種類で見分けて記録する

/// 料金（米ドル、100万トークンあたり。claude-haiku-5-5。2026-11-23 に確認）。
/// プロンプトが10万トークンを超えると、その回は全部が高い料金になる。料金が変わったらここを直す
const _tierLimit = 100000;
const _inputPrice = 0.10, _outputPrice = 0.50; // 10万トークンまで
const _inputPriceLong = 0.50, _outputPriceLong = 2.50; // 10万トークン超
const _cacheWriteRate = 1.25, _cacheReadRate = 0.1; // 入力の料金に掛ける（今のアプリはキャッシュを使っていない）

/// 期限の何日前から知らせるか
const keyExpiryNoticeDays = 14;

/// 予算の何割で知らせるか
const budgetNoticeRatio = 0.8;

/// 最後のエラーの種類
enum AiErrorKind {
  keyInvalid('APIキーが使えません（正しくないか、期限が切れています）'),
  orgSpendLimit('組織の月の利用上限に達しました（翌月1日の朝9時〈日本時間〉に戻ります）'),
  customLimit('自分で決めた利用上限に達しました'),
  credit('Anthropicの利用残高が足りません'),
  rateLimit('頼みごとが多すぎました（少し待てば使えます）'),
  server('AIが混み合っているか、一時的な問題が起きました'),
  other('AIに頼めませんでした');

  const AiErrorKind(this.label);
  final String label;
}

/// エラーの応答から種類を見分ける（Anthropic のドキュメント「Rate limits」「Errors」で確認。2026-11-22）
AiErrorKind classifyAiError(int status, String body) {
  if (status == 401 || status == 403) return AiErrorKind.keyInvalid;
  if (status == 429) {
    return body.contains('enforced_spend_limit_reached') ? AiErrorKind.orgSpendLimit : AiErrorKind.rateLimit;
  }
  if (status == 400) {
    if (body.contains('specified API usage limits')) return AiErrorKind.customLimit;
    if (body.contains('credit')) return AiErrorKind.credit;
  }
  if (status >= 500) return AiErrorKind.server;
  return AiErrorKind.other;
}

/// 1回分の料金の目安（米ドル）
double aiCostOf(Map<String, dynamic> usage) {
  int n(String k) => (usage[k] as num?)?.toInt() ?? 0;
  final input = n('input_tokens'), output = n('output_tokens');
  final cacheWrite = n('cache_creation_input_tokens'), cacheRead = n('cache_read_input_tokens');
  final long = input + cacheWrite + cacheRead > _tierLimit;
  final inPrice = long ? _inputPriceLong : _inputPrice;
  final outPrice = long ? _outputPriceLong : _outputPrice;
  return (input * inPrice +
          cacheWrite * inPrice * _cacheWriteRate +
          cacheRead * inPrice * _cacheReadRate +
          output * outPrice) /
      1000000;
}

/// 金額の書き方（1ドル未満は小数3けた）
String formatUsd(double v) => '\$${v < 1 ? v.toStringAsFixed(3) : v.toStringAsFixed(2)}';

String _monthKey(DateTime d) => '${d.year}-${pad2(d.month)}';
String _dayKey(DateTime d) => '${_monthKey(d)}-${pad2(d.day)}';
String _dateTime(DateTime d) => '${d.month}/${d.day} ${hhmm(d)}';

final aiUsage = AiUsage();

class AiUsage extends ChangeNotifier {
  SharedPreferences? _prefs;

  /// 記録している月（YYYY-MM）と、その月の回数・トークン数・使用額の目安
  String _month = '';
  int requests = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  double cost = 0;

  /// 月の予算（米ドル。null＝決めていない）
  double? budget;

  /// 最後のエラーと、最後に成功した日時
  DateTime? lastErrorAt;
  AiErrorKind? lastErrorKind;
  DateTime? lastSuccessAt;

  /// お知らせを出した印（期限＝日、予算＝月と段階）
  String _expiryNoticeDay = '';
  String _budgetNoticeMark = '';

  /// キーの期限（キーを入れるときに選ぶ。なければ null）
  DateTime? get keyExpiry => apiKeyStore.expiry;

  /// 期限まであと何日か（今日が期限なら0、切れていればマイナス。期限がなければ null）
  int? get daysLeft {
    final e = keyExpiry;
    if (e == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(e.year, e.month, e.day).difference(today).inHours ~/ 24;
  }

  /// 最後のエラーのあとに成功していないか
  bool get errorUnresolved =>
      lastErrorAt != null && (lastSuccessAt == null || lastSuccessAt!.isBefore(lastErrorAt!));

  /// 月が変わっていたら数え直す
  void _rollMonth() {
    final now = _monthKey(DateTime.now());
    if (_month == now) return;
    _month = now;
    requests = 0;
    inputTokens = 0;
    outputTokens = 0;
    cost = 0;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _month = p.getString('aiUsageMonth') ?? '';
    requests = p.getInt('aiUsageRequests') ?? 0;
    inputTokens = p.getInt('aiUsageInput') ?? 0;
    outputTokens = p.getInt('aiUsageOutput') ?? 0;
    cost = p.getDouble('aiUsageCost') ?? 0;
    budget = p.getDouble('aiBudget');
    final err = p.getInt('aiLastErrorAt');
    lastErrorAt = err == null ? null : DateTime.fromMillisecondsSinceEpoch(err);
    final kind = p.getString('aiLastErrorKind');
    lastErrorKind = AiErrorKind.values.where((k) => k.name == kind).firstOrNull;
    if (lastErrorKind == null) lastErrorAt = null;
    final ok = p.getInt('aiLastSuccessAt');
    lastSuccessAt = ok == null ? null : DateTime.fromMillisecondsSinceEpoch(ok);
    _expiryNoticeDay = p.getString('aiExpiryNoticeDay') ?? '';
    _budgetNoticeMark = p.getString('aiBudgetNoticeMark') ?? '';
    _rollMonth();
    notifyListeners();
  }

  void _saveUsage() {
    final p = _prefs;
    if (p == null) return;
    p.setString('aiUsageMonth', _month);
    p.setInt('aiUsageRequests', requests);
    p.setInt('aiUsageInput', inputTokens);
    p.setInt('aiUsageOutput', outputTokens);
    p.setDouble('aiUsageCost', cost);
  }

  /// 成功した応答の usage を足す
  void recordSuccess(Object? usage) {
    _rollMonth();
    requests++;
    if (usage is Map) {
      final u = usage.cast<String, dynamic>();
      inputTokens += ((u['input_tokens'] as num?)?.toInt() ?? 0) +
          ((u['cache_creation_input_tokens'] as num?)?.toInt() ?? 0) +
          ((u['cache_read_input_tokens'] as num?)?.toInt() ?? 0);
      outputTokens += (u['output_tokens'] as num?)?.toInt() ?? 0;
      cost += aiCostOf(u);
    }
    lastSuccessAt = DateTime.now();
    _saveUsage();
    _prefs?.setInt('aiLastSuccessAt', lastSuccessAt!.millisecondsSinceEpoch);
    notifyListeners();
  }

  /// エラーを記録する
  void recordError(AiErrorKind kind) {
    lastErrorAt = DateTime.now();
    lastErrorKind = kind;
    _prefs?.setInt('aiLastErrorAt', lastErrorAt!.millisecondsSinceEpoch);
    _prefs?.setString('aiLastErrorKind', kind.name);
    notifyListeners();
  }

  void setBudget(double? v) {
    budget = (v == null || v <= 0) ? null : v;
    if (budget == null) {
      _prefs?.remove('aiBudget');
    } else {
      _prefs?.setDouble('aiBudget', budget!);
    }
    _budgetNoticeMark = ''; // 予算を変えたら、知らせ直せるように
    _prefs?.remove('aiBudgetNoticeMark');
    notifyListeners();
  }

  /// 予算に対する割合（予算がなければ null）
  double? get budgetRatio {
    _rollMonth();
    final b = budget;
    return b == null ? null : cost / b;
  }

  /// ✨を押したときに出すお知らせ（今日・今月まだ出していないものだけ）。出したことも記録する
  List<String> takeNotices() {
    final notices = <String>[];
    final now = DateTime.now();
    final left = daysLeft;
    if (left != null && left <= keyExpiryNoticeDays && _expiryNoticeDay != _dayKey(now)) {
      _expiryNoticeDay = _dayKey(now);
      _prefs?.setString('aiExpiryNoticeDay', _expiryNoticeDay);
      notices.add(left < 0
          ? 'AnthropicのAPIキーの期限（${expiryText()}）が切れています。'
              '全体の設定の「APIキー」から、新しいキーを入れてください（ビルドし直す必要はありません）。'
          : 'AnthropicのAPIキーの期限（${expiryText()}）が近づいています。期限が来る前に、'
              '全体の設定の「APIキー」から、新しいキーを入れてください（ビルドし直す必要はありません）。');
    }
    final ratio = budgetRatio;
    if (ratio != null && ratio >= budgetNoticeRatio) {
      final level = ratio >= 1 ? 'over' : 'near';
      final mark = '$_month:$level';
      if (_budgetNoticeMark != mark) {
        _budgetNoticeMark = mark;
        _prefs?.setString('aiBudgetNoticeMark', mark);
        notices.add('今月のAIの使用額の目安が ${formatUsd(cost)} になり、月の予算 ${formatUsd(budget!)} の'
            '${(ratio * 100).floor()}%${ratio >= 1 ? 'に達しました' : 'を超えました'}。'
            '（このアプリが数えた目安です。正確な額はAnthropicのコンソールで確かめてください）');
      }
    }
    return notices;
  }

  /// 期限の書き方「2027/2/20（あと89日）」
  String expiryText() {
    final e = keyExpiry;
    final left = daysLeft;
    if (e == null || left == null) return '';
    final rest = left < 0 ? '${-left}日前に切れています' : left == 0 ? '今日まで' : 'あと$left日';
    return '${e.year}/${e.month}/${e.day}（$rest）';
  }

  /// 最後のエラーの書き方
  String lastErrorText() {
    final at = lastErrorAt, kind = lastErrorKind;
    if (at == null || kind == null) return '';
    final after = errorUnresolved ? '' : '（そのあと ${_dateTime(lastSuccessAt!)} に使えています）';
    return '${_dateTime(at)}：${kind.label}$after';
  }

  /// 今月の使用額の書き方「約 $0.012（34回）／予算 $5（1%）」
  String usageText() {
    _rollMonth();
    final b = budget;
    final base = '約 ${formatUsd(cost)}（$requests回）';
    return b == null ? base : '$base／予算 ${formatUsd(b)}（${(cost / b * 100).floor()}%）';
  }

  /// ✨に渡す説明（キーそのものは渡さない。日付と金額だけ）
  String forAi() {
    _rollMonth();
    final buf = StringBuffer('\n\n【APIキーと利用料（このアプリが記録した情報）】');
    buf.write(keyExpiry == null
        ? 'APIキーの期限：なし、または分かりません（全体の設定の「APIキー」で、キーを入れるときに選べます）。'
        : 'APIキーの期限：${expiryText()}。');
    buf.write('今月（${_month.replaceFirst('-', '年')}月）このアプリから使った額の目安：${usageText()}、'
        '入力$inputTokensトークン・出力$outputTokensトークン。');
    if (budget == null) buf.write('月の予算：決めていません（全体の設定で入れられます）。');
    final err = lastErrorText();
    buf.write(err.isEmpty ? '最近のエラー：なし。' : '最後のエラー：$err。');
    buf.write('APIキーの期限・利用料・上限について聞かれたら、これをもとに answer で答えてください。'
        '使用額はこのアプリが数えた目安で、同じキーをほかで使った分は入らないこと、'
        '正確な額や上限はAnthropicのコンソールで確かめられることも短く添えてください。'
        'APIキーそのものはここにはなく、答えにも書かないでください。');
    return buf.toString();
  }

  /// 「端末内のデータを消す」のあと（SharedPreferences.clear のあとに呼ぶ）
  void clearLocal() {
    _month = '';
    _rollMonth();
    budget = null;
    lastErrorAt = null;
    lastErrorKind = null;
    lastSuccessAt = null;
    _expiryNoticeDay = '';
    _budgetNoticeMark = '';
    notifyListeners();
  }
}
