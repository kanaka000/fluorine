import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'errors.dart';

/// Google Cloud「Fluorine Web」のクライアントID（公開しても問題ない値）
/// Google Cloud のウェブ用OAuthクライアントID（serverClientId）。
/// 各自の値を secrets.json の GOOGLE_WEB_CLIENT_ID に入れる（2026-11-18 コードの直書きをやめた）
const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

/// クライアントIDが入っているか（空・見本のままなら false。そのときGoogle連携は止める）
final bool googleConfigured = () {
  final v = webClientId.trim();
  return v.isNotEmpty && !v.contains('ここに') && v.endsWith('.apps.googleusercontent.com');
}();

/// クライアントIDが未設定のときにログインしようとしたら出すエラー
class GoogleNotConfigured extends AppMessage {
  const GoogleNotConfigured()
      : super('secrets.json に GOOGLE_WEB_CLIENT_ID（Google Cloud のウェブ用クライアントID）が入っていません。'
            '入れてからアプリを起動し直してください');
}

/// アプリが使う権限（Gmailの読み取り・既読化、カレンダーの予定、ToDoリスト）
const googleScopes = <String>[
  'https://www.googleapis.com/auth/gmail.modify',
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/tasks',
];

final googleAuth = GoogleAuth();

/// Googleアカウントのログイン状態を管理する
class GoogleAuth extends ChangeNotifier {
  GoogleSignInAccount? _user;
  bool initialized = false;

  /// ログイン中のアカウント
  GoogleSignInAccount? get user => _user;

  /// アカウントが変わる（ログイン・ログアウト・切り替え）たびに進む番号（2026-11-18 セキュリティ対策 A08）。
  /// 読み込みを始めたときの番号と、終わったときの番号が違えば、その結果は前のアカウントのものなので捨てる
  int session = 0;

  set user(GoogleSignInAccount? u) {
    if (u?.id != _user?.id) session++;
    _user = u;
  }

  /// 読み込みの途中でアカウントが変わっていたら StaleSession を投げる
  void checkSession(int gen) {
    if (gen != session) throw StaleSession();
  }

  bool get signedIn => user != null;

  Future<void> init() async {
    if (!googleConfigured) {
      // クライアントIDがないときはGoogleにつながない（メモだけ使える）
      devLog('GOOGLE_WEB_CLIENT_ID が未設定のため、Google連携を止めています');
      initialized = true;
      notifyListeners();
      return;
    }
    final signIn = GoogleSignIn.instance;
    await signIn.initialize(serverClientId: webClientId);
    signIn.authenticationEvents.listen((event) {
      user = switch (event) {
        GoogleSignInAuthenticationEventSignIn() => event.user,
        GoogleSignInAuthenticationEventSignOut() => null,
      };
      notifyListeners();
    }).onError((Object e) {
      devLog('Google sign-in error: $e');
    });
    // 以前ログインしていれば、画面を出さずにログイン状態を復元する
    final restored = await signIn.attemptLightweightAuthentication();
    if (restored != null) user = restored;
    initialized = true;
    notifyListeners();
  }

  /// ログイン画面を出してログインする（ボタンを押したときに呼ぶ）
  Future<void> signIn() async {
    if (!googleConfigured) throw const GoogleNotConfigured();
    user = await GoogleSignIn.instance.authenticate();
    notifyListeners();
  }

  Future<void> signOut() async {
    // 先にログアウトの状態にして番号を進める（読み込み中の結果をすぐ捨てられるように）
    user = null;
    notifyListeners();
    if (googleConfigured) await GoogleSignIn.instance.disconnect();
  }

  /// Google APIを呼べるHTTPクライアントを返す。
  /// prompt=true のときは、まだ許可していなければ許可画面を出す（ボタン操作の中でのみ）
  Future<http.Client?> authorizedClient({bool prompt = false}) async {
    final u = user;
    if (u == null) return null;
    final headers = await u.authorizationClient
        .authorizationHeaders(googleScopes, promptIfNecessary: prompt);
    if (headers == null) return null;
    return _AuthClient(u, headers);
  }
}

/// Google APIに送るリクエストに、ログイン中のアクセストークンを付けるクライアント。
/// アクセストークンは約1時間で切れるので（2026-11-16 修正：以前は最初のトークンを使い続けて401になっていた）
/// - 数分ごとに取り直す（端末側でキャッシュされているので軽い）
/// - それでも401（認証エラー）が返ったら、そのトークンを捨てて取り直し、1回だけ送り直す
class _AuthClient extends http.BaseClient {
  _AuthClient(this._user, this._headers) : _fetchedAt = DateTime.now();

  final GoogleSignInAccount _user;
  Map<String, String> _headers;
  DateTime _fetchedAt;
  Future<void>? _refreshing;
  final http.Client _inner = http.Client();

  /// この時間がたったら、送る前にトークンを取り直す
  static const _maxAge = Duration(minutes: 5);

  /// トークンを取り直す（同時に何件も送るときは1回にまとめる）
  Future<void> _refresh({bool clearOld = false}) {
    return _refreshing ??= () async {
      try {
        if (clearOld) {
          final token = _headers['Authorization']?.replaceFirst('Bearer ', '');
          if (token != null && token.isNotEmpty) {
            await _user.authorizationClient.clearAuthorizationToken(accessToken: token);
          }
        }
        final h = await _user.authorizationClient
            .authorizationHeaders(googleScopes, promptIfNecessary: false);
        if (h != null) _headers = h;
        _fetchedAt = DateTime.now();
      } catch (e) {
        devLog('アクセストークンの取り直しに失敗: $e');
      } finally {
        _refreshing = null;
      }
    }();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (DateTime.now().difference(_fetchedAt) > _maxAge) await _refresh();
    // 401のときに送り直せるよう、本文を先に取り出しておく
    final body = await request.finalize().toBytes();
    final used = _headers['Authorization']; // このリクエストに付けたトークン
    // 時間切れ（2026-11-18 B08）。大きな送信（添付付きのメールなど）は長めに待つ
    final limit = Duration(seconds: body.length > 1000000 ? 180 : 30);
    var res = await _inner.send(_copy(request, body)).timeout(limit);
    if (res.statusCode == 401) {
      await res.stream.drain<void>();
      // 他のリクエストがすでに取り直していれば、捨てずにその新しいトークンを使う
      await _refresh(clearOld: _headers['Authorization'] == used);
      res = await _inner.send(_copy(request, body)).timeout(limit);
    }
    return res;
  }

  /// 元のリクエストと同じ内容で、今のトークンを付けた新しいリクエストを作る
  http.Request _copy(http.BaseRequest original, List<int> body) {
    return http.Request(original.method, original.url)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection
      ..headers.addAll(original.headers)
      ..headers.addAll(_headers)
      ..bodyBytes = body;
  }

  @override
  void close() => _inner.close();
}

/// ログアウト・アカウントの切り替えの前に始めた読み込みの結果（捨てる）
class StaleSession implements Exception {}
