import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'translator.dart';

// ---------------------------------------------------------------- 모델

class ApiError implements Exception {
  ApiError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

int _int(dynamic v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(dynamic v) => (v as num?)?.toInt();

class Me {
  Me.fromJson(Map<String, dynamic> m)
      : id = m['id'] as String,
        nickname = m['nickname'] as String,
        coins = _int(m['coins']),
        gender = m['gender'] as String? ?? '',
        age = _int(m['age']),
        birthYear = _int(m['birthYear']),
        lang = m['lang'] as String?,
        emoji = m['emoji'] as String? ?? '🙂';
  final String id;
  final String emoji; // QR 위에 보이는 내 이모지
  final String? lang; // 마지막으로 고른 대화 언어 (새 대화방 기본값)
  final String nickname;
  final int coins;
  final String gender; // M, F
  final int age;
  final int birthYear;

  String get genderLabel => gender == 'F' ? '여성' : '남성';
}

/// 간편인증 결과로 자동 입력되는 가입 정보
class SignupProfile {
  SignupProfile.fromJson(Map<String, dynamic> m)
      : age = _int(m['age']),
        birthYear = _int(m['birthYear']),
        gender = m['gender'] as String? ?? '';
  final int age;
  final int birthYear;
  final String gender;
  String get genderLabel => gender == 'F' ? '여성' : '남성';
}

/// 이모지 고르기·사기·신청 화면 데이터
class EmojiCatalog {
  EmojiCatalog.fromJson(Map<String, dynamic> m)
      : current = m['current'] as String? ?? '🙂',
        free = (m['free'] as List? ?? const []).cast<String>(),
        shop = (m['shop'] as List? ?? const []).map((e) => ShopEmoji.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
        requests = (m['requests'] as List? ?? const []).map((e) => EmojiRequest.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  final String current;
  final List<String> free;
  final List<ShopEmoji> shop;
  final List<EmojiRequest> requests;
}

class ShopEmoji {
  ShopEmoji.fromJson(Map<String, dynamic> m)
      : id = m['id'] as String,
        emoji = m['emoji'] as String,
        price = _int(m['price']),
        owned = m['owned'] == true;
  final String id;
  final String emoji;
  final int price;
  final bool owned;
}

class EmojiRequest {
  EmojiRequest.fromJson(Map<String, dynamic> m)
      : emoji = m['emoji'] as String?,
        note = m['note'] as String? ?? '',
        status = m['status'] as String? ?? 'pending',
        answer = m['answer'] as String?;
  final String? emoji;
  final String note;
  final String status; // pending, approved, rejected
  final String? answer;
  String get statusLabel => switch (status) { 'approved' => '승인', 'rejected' => '반려', _ => '검토 중' };
}

/// 앱이 지금 보여줘야 하는 단계
enum Stage { loading, setup, identity, signup, blocked, ready }

class ExtInfo {
  ExtInfo.fromJson(Map<String, dynamic> m)
      : mine = m['mine'] == true,
        status = m['status'] as String,
        attempt = _int(m['attempt']),
        requestedAt = _int(m['requestedAt']),
        respondBy = _int(m['respondBy']),
        rejectedAt = _intOrNull(m['rejectedAt']),
        reasonText = m['reasonText'] as String?,
        reasonLocked = m['reasonLocked'] == true,
        retryAt = _intOrNull(m['retryAt']);
  final bool mine;
  final String status;
  final int attempt;
  final int requestedAt;
  final int respondBy;
  final int? rejectedAt;
  final String? reasonText;
  final bool reasonLocked;
  final int? retryAt;
}

class Room {
  Room.fromJson(Map<String, dynamic> m)
      : id = m['id'] as String,
        partnerNickname = m['partnerNickname'] as String,
        partnerEmoji = m['partnerEmoji'] as String?,
        myLang = m['myLang'] as String?,
        partnerLang = m['partnerLang'] as String?,
        via = m['via'] as String? ?? 'qr',
        createdAt = _int(m['createdAt']),
        memo = m['memo'] as String? ?? '',
        hidden = m['hidden'] == true,
        reported = m['reported'] == true,
        unread = _int(m['unread']),
        status = m['status'] as String,
        endsAt = _intOrNull(m['endsAt']),
        windowEnd = _intOrNull(m['windowEnd']),
        ext = m['ext'] == null ? null : ExtInfo.fromJson(Map<String, dynamic>.from(m['ext'] as Map)),
        lastText = (m['lastMessage'] as Map?)?['text'] as String?,
        lastAt = _intOrNull((m['lastMessage'] as Map?)?['at']),
        serverNow = _int(m['serverNow']);
  final String id;
  final String partnerNickname;
  final String? partnerEmoji;
  final String? myLang; // 이 대화방에서 내가 쓰는 언어 (처음 들어올 때 고른다)
  final String? partnerLang;
  final String via;
  final int createdAt;
  final String memo;
  final bool hidden;
  final bool reported;
  final int unread; // 안 읽은 상대 메시지 수
  final String status; // live, extended, pending, ended, rejected, expired
  final int? endsAt;
  final int? windowEnd;
  final ExtInfo? ext;
  final String? lastText;
  final int? lastAt;
  final int serverNow;

  bool get isLive => status == 'live' || status == 'extended';
}

class Msg {
  Msg.fromJson(Map<String, dynamic> m)
      : id = m['id'] as String,
        text = m['text'] as String,
        lang = m['lang'] as String?,
        trLang = (m['tr'] as Map?)?['lang'] as String?,
        trText = (m['tr'] as Map?)?['text'] as String?,
        at = _int(m['at']),
        system = m['system'] == true,
        mine = m['mine'] == true;
  final String id;
  final String text; // 보낸 사람이 쓴 원문
  final String? lang; // 원문 언어
  final String? trLang; // 보낸 사람이 함께 보낸 번역본 (상대 언어)
  final String? trText;
  final int at;
  final bool system;
  final bool mine;
}

class Reason {
  Reason.fromJson(Map<String, dynamic> m)
      : id = m['id'] as String,
        text = m['text'] as String,
        custom = m['custom'] == true;
  final String id;
  final String text;
  final bool custom;
}

class QrInfo {
  QrInfo(this.token, this.url, this.expiresAt);
  final String token;
  final String url;
  final int expiresAt;
}

// 화면 어디에 있든 반응해야 하는 일들
sealed class AppEvent {}

class QrUsedEvent extends AppEvent {
  QrUsedEvent(this.roomId, {this.reused = false});
  final String roomId;
  final bool reused; // 같은 사람이 다시 찍어서 기존 대화방이 열린 경우
}

class ExtIncomingEvent extends AppEvent {
  ExtIncomingEvent(this.roomId, this.fromNickname);
  final String roomId;
  final String fromNickname;
}

class NickRequestEvent extends AppEvent {
  NickRequestEvent(this.reqId, this.fromNickname);
  final String reqId;
  final String fromNickname;
}

class NickResultEvent extends AppEvent {
  NickResultEvent(this.accepted, this.roomId);
  final bool accepted;
  final String? roomId;
}

// ---------------------------------------------------------------- 상태

/// 빌드할 때 넣는 서버 주소 (flutter build apk --dart-define=SERVER_URL=https://...)
const kServerUrl = String.fromEnvironment('SERVER_URL');

class AppState extends ChangeNotifier {
  late SharedPreferences _prefs;
  // 기기 토큰과 로그인 토큰은 안드로이드 키스토어 / iOS 키체인에 보관한다
  final _secure = const FlutterSecureStorage();
  String? server;
  String? _deviceToken;
  String? _session;
  io.Socket? _socket;
  bool connected = false;
  bool bootstrapped = false;
  Stage stage = Stage.loading;
  String? bootError;
  SignupProfile? signupProfile;
  String? _verificationId;
  Map<String, dynamic>? blockedInfo;
  String? pendingJoin; // 로그인 전에 찍은 QR: 로그인 뒤 바로 들어간다
  String? openRoomId; // 지금 화면에 열려 있는 대화방
  bool lastJoinReused = false;

  // ---------------- 번역
  /// 받은 메시지를 내 폰에서 번역한 결과 (상대가 번역 없이 보냈을 때)
  final Map<String, String> localTr = {};
  final Set<String> _translating = {};
  bool translateOn(String roomId) => _prefs.getBool('tr:$roomId') ?? false;
  Future<void> setTranslate(String roomId, bool on) async {
    await _prefs.setBool('tr:$roomId', on);
    notifyListeners();
    if (on) unawaited(translateIncoming(roomId));
  }

  int get totalUnread => rooms.values.where((r) => !r.hidden && r.status != 'expired').fold(0, (sum, r) => sum + r.unread);
  Me? me;
  Map<String, num> settings = {};
  List<Reason> reasons = [];
  List<String> reportReasons = [];
  final Map<String, Room> rooms = {};
  final Map<String, List<Msg>> messages = {};
  QrInfo? qr;
  int qrRenewedAt = 0;
  int _offset = 0;
  final _events = StreamController<AppEvent>.broadcast();
  Stream<AppEvent> get events => _events.stream;
  Completer<void>? _ready;

  int get now => DateTime.now().millisecondsSinceEpoch + _offset;
  int setting(String k, [int fallback = 0]) => settings[k]?.toInt() ?? fallback;

  void _go(Stage s) {
    stage = s;
    notifyListeners();
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // iOS 는 앱을 지워도 키체인이 남는다. 새로 설치한 경우 예전 토큰을 지워 다시 인증하게 한다
    if (_prefs.getBool('installed') != true) {
      await _secure.deleteAll();
      await _prefs.setBool('installed', true);
    }
    server = _prefs.getString('server') ?? (kServerUrl.isEmpty ? null : normalize(kServerUrl));
    if (server == null) {
      _go(Stage.setup);
    } else {
      unawaited(boot());
    }
  }

  static String normalize(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    final u = Uri.parse(s);
    return u.origin;
  }

  /// 서버 주소를 직접 정할 때 (테스트용)
  Future<void> setServer(String raw) async {
    final url = normalize(raw);
    final res = await http.get(Uri.parse('$url/health')).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw ApiError('server', '서버 응답이 없어요');
    server = url;
    await _prefs.setString('server', url);
    rooms.clear();
    messages.clear();
    qr = null;
    await boot();
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_deviceToken != null) 'X-Device-Token': _deviceToken!,
        if (_session != null) 'Authorization': 'Bearer $_session',
      };

  Future<(int, Map<String, dynamic>)> _api(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$server$path');
    // 무료 서버는 잠들어 있다가 깨는 데 1분 가까이 걸릴 수 있다
    const wait = Duration(seconds: 70);
    final res = method == 'GET'
        ? await http.get(uri, headers: _headers).timeout(wait)
        : await http.post(uri, headers: _headers, body: jsonEncode(body ?? {})).timeout(wait);
    Map<String, dynamic> data = {};
    try {
      data = Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)) as Map);
    } catch (_) {}
    return (res.statusCode, data);
  }

  /// 1단계: 기기 인증. 이 기기 전용 토큰을 받아 보안 저장소에 둔다.
  Future<void> _registerDevice() async {
    _session = null;
    _deviceToken = null;
    final (code, d) = await _api('POST', '/api/device/register', {
      'platform': Platform.isIOS ? 'ios' : 'android',
      'model': Platform.operatingSystemVersion.length > 60 ? Platform.operatingSystemVersion.substring(0, 60) : Platform.operatingSystemVersion,
    });
    if (code != 200) throw ApiError('device', '기기 인증에 실패했어요');
    _deviceToken = d['deviceToken'] as String;
    await _secure.write(key: 'device:$server', value: _deviceToken);
  }

  /// 앱 시작: 기기 인증 → 저장된 로그인 확인(자동로그인) → 안 되면 간편인증 화면
  Future<void> boot() async {
    bootError = null;
    _go(Stage.loading);
    try {
      _deviceToken = await _secure.read(key: 'device:$server');
      _session = await _secure.read(key: 'session:$server');
      if (_deviceToken == null) await _registerDevice();
      if (_session != null) {
        final (code, d) = await _api('GET', '/api/check');
        if (code == 200) {
          await connect();
          return;
        }
        if (code == 403) {
          blockedInfo = d;
          _go(Stage.blocked);
          return;
        }
        await _clearSession();
      }
      _go(Stage.identity);
    } catch (e) {
      bootError = e is ApiError ? e.message : '서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요';
      notifyListeners();
    }
  }

  Future<void> _clearSession() async {
    _session = null;
    await _secure.delete(key: 'session:$server');
  }

  Future<void> _saveSession(String token) async {
    _session = token;
    await _secure.write(key: 'session:$server', value: token);
  }

  /// 2단계: 간편인증 (테스트 버전은 이름·생년월일·성별·번호를 직접 입력)
  Future<void> verifyIdentity({required String name, required String birth, required String gender, required String phone}) =>
      _completeIdentity({
        'mock': {'name': name, 'birth': birth, 'gender': gender, 'phone': phone},
      });

  /// 카카오로 가입·로그인. 카카오 SDK로 받은 토큰을 서버가 카카오에 다시 확인한다.
  /// (앱에 카카오 키가 없는 테스트 빌드는 kakaoMock 으로 카카오 계정 정보를 흉내 낸다)
  Future<void> verifyKakao({String? accessToken, Map<String, dynamic>? mock}) => _completeIdentity({
        'kakao': {if (accessToken != null) 'accessToken': accessToken, if (mock != null) 'mock': mock},
      });

  Future<void> _completeIdentity(Map<String, dynamic> payload) async {
    var (code, st) = await _api('POST', '/api/identity/start');
    if (code == 401) {
      await _registerDevice(); // 서버 데이터가 초기화된 경우 기기 인증부터 다시
      (code, st) = await _api('POST', '/api/identity/start');
    }
    if (code != 200) throw ApiError('start', st['message']?.toString() ?? '인증을 시작하지 못했어요');
    final vid = st['verificationId'] as String;
    final (c2, d) = await _api('POST', '/api/identity/complete', {'verificationId': vid, ...payload});
    if (c2 == 403 && d['error'] == 'blocked') {
      blockedInfo = d;
      _go(Stage.blocked);
      return;
    }
    if (c2 != 200) throw ApiError(d['error']?.toString() ?? 'verify', d['message']?.toString() ?? '인증하지 못했어요');
    if (d['status'] == 'login') {
      // 이미 가입한 사람: 이 기기로 로그인 (예전 기기는 로그아웃)
      await _saveSession(d['token'] as String);
      await connect();
      return;
    }
    _verificationId = vid;
    signupProfile = SignupProfile.fromJson(_map(d['profile']));
    _go(Stage.signup);
  }

  /// 3단계: 가입 (나이·성별은 자동 입력, 약관 동의만)
  Future<void> signup({required bool terms, required bool privacy, required bool marketing}) async {
    final (code, d) = await _api('POST', '/api/signup', {
      'verificationId': _verificationId,
      'agreeTerms': terms,
      'agreePrivacy': privacy,
      'agreeMarketing': marketing,
    });
    if (code != 200) {
      if (d['error'] == 'verification') _go(Stage.identity);
      throw ApiError(d['error']?.toString() ?? 'signup', d['message']?.toString() ?? '가입하지 못했어요');
    }
    await _saveSession(d['token'] as String);
    await connect();
  }

  void backToIdentity() => _go(Stage.identity);

  Future<void> connect() async {
    if (server == null || _session == null) return;
    _socket?.dispose();
    bootstrapped = false;
    final ready = _ready = Completer<void>();

    final s = io.io(
      server!,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': _session})
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );
    _socket = s;

    s.onConnect((_) async {
      connected = true;
      notifyListeners();
      try {
        await _bootstrap();
        stage = Stage.ready;
        notifyListeners();
        if (!ready.isCompleted) ready.complete();
      } catch (e) {
        if (!ready.isCompleted) ready.completeError(e);
      }
    });
    s.onDisconnect((reason) {
      connected = false;
      notifyListeners();
      // 관리자가 차단했거나 다른 기기에서 로그인하면 서버가 연결을 끊는다
      if (reason == 'io server disconnect') unawaited(boot());
    });
    s.onConnectError((err) {
      connected = false;
      notifyListeners();
      final msg = err.toString();
      if (msg.contains('unauthorized') || msg.contains('blocked')) {
        s.dispose();
        unawaited(boot());
      }
    });

    s.on('me:update', (d) {
      me = Me.fromJson(_map(d));
      notifyListeners();
    });
    s.on('room:update', (d) {
      final r = Room.fromJson(_map(d));
      _offset = r.serverNow - DateTime.now().millisecondsSinceEpoch;
      rooms[r.id] = r;
      notifyListeners();
    });
    s.on('msg', (d) {
      final m = _map(d);
      final roomId = m['roomId'] as String;
      final msg = Msg.fromJson(_map(m['message']));
      final list = messages[roomId];
      if (list != null && !list.any((x) => x.id == msg.id)) list.add(msg);
      if (!msg.mine && !msg.system) unawaited(translateIncoming(roomId));
      // 지금 보고 있는 대화방이면 바로 읽음 처리
      if (roomId == openRoomId && !msg.mine) unawaited(call('room:read', {'roomId': roomId}).then((_) {}, onError: (_) {}));
      notifyListeners();
    });
    s.on('qr:used', (d) {
      final m = _map(d);
      _events.add(QrUsedEvent(m['roomId'] as String, reused: m['reused'] == true));
      unawaited(newQr().catchError((_) {}));
    });
    s.on('ext:incoming', (d) {
      final m = _map(d);
      _events.add(ExtIncomingEvent(m['roomId'] as String, m['fromNickname'] as String));
    });
    s.on('nick:request', (d) {
      final m = _map(d);
      _events.add(NickRequestEvent(m['reqId'] as String, m['fromNickname'] as String));
    });
    s.on('nick:result', (d) {
      final m = _map(d);
      _events.add(NickResultEvent(m['accepted'] == true, m['roomId'] as String?));
    });

    s.connect();
    return ready.future.timeout(const Duration(seconds: 70), onTimeout: () {
      throw ApiError('timeout', '서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요');
    });
  }

  Future<void> _bootstrap() async {
    final m = await call('me');
    me = Me.fromJson(_map(m['user']));
    settings = _map(m['settings']).map((k, v) => MapEntry(k, v as num));
    reportReasons = ((m['reportReasons'] as List?) ?? const []).map((e) => e.toString()).toList();
    final rs = await call('reasons:list');
    reasons = (rs['reasons'] as List).map((e) => Reason.fromJson(_map(e))).toList();
    final list = await call('rooms:list');
    rooms.clear();
    for (final e in list['rooms'] as List) {
      final r = Room.fromJson(_map(e));
      _offset = r.serverNow - DateTime.now().millisecondsSinceEpoch;
      rooms[r.id] = r;
    }
    bootstrapped = true;
    notifyListeners();
  }

  Future<void> waitReady() async {
    if (bootstrapped && connected) return;
    final r = _ready;
    if (r != null) await r.future.timeout(const Duration(seconds: 10));
  }

  static Map<String, dynamic> _map(dynamic d) => Map<String, dynamic>.from(d as Map);

  Future<Map<String, dynamic>> call(String event, [Map<String, dynamic>? data]) {
    final s = _socket;
    if (s == null) return Future.error(ApiError('offline', '서버에 연결되지 않았어요'));
    final c = Completer<Map<String, dynamic>>();
    s.emitWithAck(event, data ?? <String, dynamic>{}, ack: (dynamic res) {
      final m = _map(res is List && res.isNotEmpty ? res.first : res);
      if (m['ok'] == true) {
        c.complete(m);
      } else {
        c.completeError(ApiError(m['error']?.toString() ?? 'error', m['message']?.toString() ?? '실패했어요'));
      }
    });
    return c.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw ApiError('timeout', '서버 응답이 늦어요. 다시 시도해 주세요'));
  }

  // ---------------------------------------------------------------- 동작

  Future<void> newQr() async {
    final m = await call('qr:new');
    _offset = _int(m['serverNow']) - DateTime.now().millisecondsSinceEpoch;
    final wasExpired = qr != null && qr!.expiresAt <= now;
    qr = QrInfo(m['token'] as String, m['url'] as String, _int(m['expiresAt']));
    if (wasExpired) qrRenewedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  Future<void> reroll() async {
    final m = await call('nick:reroll');
    me = Me.fromJson(_map(m['user']));
    notifyListeners();
  }

  /// QR(앱 스캐너, 딥링크)에서 읽은 값으로 대화방에 들어간다.
  Future<Room> joinFromCode(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    String? token;
    String? origin;
    if (uri != null && uri.scheme == 'fivechat' && uri.host == 'join' && uri.pathSegments.isNotEmpty) {
      token = uri.pathSegments.first;
      origin = uri.queryParameters['server'];
    } else if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final i = uri.pathSegments.indexOf('j');
      if (i >= 0 && i + 1 < uri.pathSegments.length) {
        token = uri.pathSegments[i + 1];
        origin = uri.origin;
      }
    }
    if (token == null) throw ApiError('bad_qr', '5분 채팅 QR이 아니에요');
    if (origin != null && normalize(origin) != server) {
      if (stage == Stage.ready) throw ApiError('other_server', '다른 서버의 QR이에요. 메뉴의 서버 주소 바꾸기에서 바꿔 주세요');
      await setServer(origin);
    }
    if (stage != Stage.ready) {
      // 아직 로그인 전이면 인증을 마친 뒤 이 QR로 바로 들어간다
      pendingJoin = raw;
      throw ApiError('later', '인증을 마치면 바로 대화방이 열려요');
    }
    await waitReady();
    final m = await call('join', {'token': token});
    final room = Room.fromJson(_map(m['room']));
    lastJoinReused = m['reused'] == true;
    rooms[room.id] = room;
    notifyListeners();
    return room;
  }

  Future<void> connectNickname(String nickname) => call('nick:connect', {'nickname': nickname.trim()});

  Future<String?> respondNick(String reqId, bool accept) async {
    final m = await call('nick:respond', {'reqId': reqId, 'accept': accept});
    if (m['room'] == null) return null;
    final r = Room.fromJson(_map(m['room']));
    rooms[r.id] = r;
    unawaited(newQr().catchError((_) {}));
    notifyListeners();
    return r.id;
  }

  Future<void> loadRoom(String roomId) async {
    final m = await call('room:get', {'roomId': roomId});
    rooms[roomId] = Room.fromJson(_map(m['room']));
    messages[roomId] = (m['messages'] as List).map((e) => Msg.fromJson(_map(e))).toList();
    notifyListeners();
    unawaited(translateIncoming(roomId));
  }

  // ---------------- 이모지
  Future<EmojiCatalog> emojiList() async => EmojiCatalog.fromJson(await call('emoji:list'));
  Future<EmojiCatalog> setEmoji(String emoji) async => EmojiCatalog.fromJson(await call('emoji:set', {'emoji': emoji}));
  Future<EmojiCatalog> buyEmoji(String id) async => EmojiCatalog.fromJson(await call('emoji:buy', {'id': id}));
  Future<EmojiCatalog> requestEmoji(String emoji, String note) async =>
      EmojiCatalog.fromJson(await call('emoji:request', {'emoji': emoji, 'note': note}));

  Future<void> setRoomLang(String roomId, String lang) async {
    final m = await call('room:lang', {'roomId': roomId, 'lang': lang});
    rooms[roomId] = Room.fromJson(_map(m['room']));
    notifyListeners();
    unawaited(translateIncoming(roomId));
  }

  /// 보내기. 번역이 켜져 있고 상대 언어가 다르면 상대 언어 번역본을 같이 보낸다
  Future<void> send(String roomId, String text) async {
    final room = rooms[roomId];
    Map<String, String>? tr;
    final from = room?.myLang, to = room?.partnerLang;
    if (room != null && translateOn(roomId) && from != null && to != null && from != to) {
      final t = Translator.instance;
      final missing = await t.missing(from, to);
      if (missing.isNotEmpty) throw ApiError('lang_pack', '번역 언어 팩을 먼저 받아 주세요');
      tr = {'lang': to, 'text': await t.translate(text, from: from, to: to)};
    }
    await call('msg:send', {'roomId': roomId, 'text': text, if (tr != null) 'tr': tr});
  }

  /// 화면에 보여줄 상대 메시지: 내 언어 번역본이 있으면 그것, 원문은 작게
  ({String main, String? sub}) shown(Msg m, Room? room) {
    if (m.mine) return (main: m.text, sub: m.trText != null && m.trText != m.text ? '→ ${m.trText}' : null);
    final my = room?.myLang;
    String? t;
    if (m.trText != null && m.trLang == my) {
      t = m.trText;
    } else if (room != null && translateOn(room.id)) {
      t = localTr[m.id];
    }
    if (t == null || t == m.text) return (main: m.text, sub: null);
    return (main: t, sub: '원문: ${m.text}');
  }

  /// 번역이 켜져 있으면, 내 언어 번역본 없이 온 상대 메시지를 내 폰에서 번역한다
  Future<void> translateIncoming(String roomId) async {
    final room = rooms[roomId];
    final my = room?.myLang;
    if (room == null || my == null || !translateOn(roomId)) return;
    final t = Translator.instance;
    for (final m in List.of(messages[roomId] ?? const <Msg>[])) {
      if (m.mine || m.system || localTr.containsKey(m.id) || _translating.contains(m.id)) continue;
      if (m.trText != null && m.trLang == my) continue;
      final src = m.lang ?? room.partnerLang;
      if (src == null || src == my) continue;
      if ((await t.missing(src, my)).isNotEmpty) return;
      _translating.add(m.id);
      try {
        localTr[m.id] = await t.translate(m.text, from: src, to: my);
        notifyListeners();
      } catch (_) {
        // 번역에 실패하면 원문을 그대로 보여준다
      } finally {
        _translating.remove(m.id);
      }
    }
  }

  Future<void> setMemo(String roomId, String text) => call('memo:set', {'roomId': roomId, 'text': text});

  Future<void> setHidden(String roomId, bool hidden) => call('room:hide', {'roomId': roomId, 'hidden': hidden});

  Future<void> requestExtension(String roomId) => call('ext:request', {'roomId': roomId});

  Future<void> respondExtension(String roomId, {required bool accept, String? reasonId, String? reasonText}) =>
      call('ext:respond', {'roomId': roomId, 'accept': accept, 'reasonId': reasonId, 'reasonText': reasonText});

  Future<void> viewReason(String roomId) async {
    final m = await call('ext:viewReason', {'roomId': roomId});
    final r = Room.fromJson(_map(m['room']));
    rooms[r.id] = r;
    notifyListeners();
  }

  Future<void> report(String roomId, String reason, String detail) =>
      call('report', {'roomId': roomId, 'reason': reason, 'detail': detail});

  Future<void> resetServer() async {
    _socket?.dispose();
    _socket = null;
    server = null;
    stage = Stage.setup;
    me = null;
    connected = false;
    bootstrapped = false;
    rooms.clear();
    messages.clear();
    qr = null;
    await _prefs.remove('server');
    notifyListeners();
  }
}

// ---------------------------------------------------------------- 전역 접근

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

// ---------------------------------------------------------------- 표시 도우미

String pad2(int n) => n.toString().padLeft(2, '0');

String clockText(int ms) {
  final raw = (ms / 1000).ceil();
  final s = raw < 0 ? 0 : raw;
  return '${s ~/ 60}:${pad2(s % 60)}';
}

String hmText(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour;
  return '${h < 12 ? '오전' : '오후'} ${h % 12 == 0 ? 12 : h % 12}:${pad2(d.minute)}';
}

String memoShort(String memo) => memo.isEmpty ? '메모 추가' : (memo.characters.length > 7 ? '${memo.characters.take(7)}…' : memo);
