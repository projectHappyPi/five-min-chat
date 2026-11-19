import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'screens/auth_screens.dart';
import 'screens/chat_screen.dart';
import 'screens/ext_sheet.dart';
import 'screens/home_shell.dart';
import 'screens/setup_screen.dart';
import 'state.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void toast(String text) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

void openChat(String roomId) {
  navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => ChatScreen(roomId: roomId)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();
  runApp(FiveMinChat(state: state));
}

class FiveMinChat extends StatelessWidget {
  const FiveMinChat({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: '5분 채팅',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: const Root(),
      ),
    );
  }
}

/// 서버 주소가 없으면 시작 화면, 있으면 홈. 전역 이벤트(연장 요청, 닉네임 요청, 딥링크)를 받는다.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  StreamSubscription<AppEvent>? _events;
  StreamSubscription<Uri>? _links;
  final _appLinks = AppLinks();
  String? _lastLink;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_events != null) return;
    final state = AppScope.read(context);
    _events = state.events.listen(_onEvent);
    _links = _appLinks.uriLinkStream.listen(_onLink);
    _appLinks.getInitialLink().then((u) {
      if (u != null) _onLink(u);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    _links?.cancel();
    super.dispose();
  }

  Future<void> _onLink(Uri uri) async {
    final s = uri.toString();
    if (s == _lastLink || uri.scheme != 'fivechat') return;
    _lastLink = s;
    final state = AppScope.read(context);
    try {
      final room = await state.joinFromCode(s);
      openChat(room.id);
    } catch (e) {
      toast(e.toString());
    }
  }

  Future<void> _onEvent(AppEvent e) async {
    final state = AppScope.read(context);
    switch (e) {
      case QrUsedEvent(:final roomId):
        toast('상대가 QR을 찍었어요. 대화방이 열렸어요');
        openChat(roomId);
      case ExtIncomingEvent(:final roomId, :final fromNickname):
        toast('$fromNickname님이 대화를 더 하고 싶어해요');
        final ctx = navigatorKey.currentContext;
        if (ctx != null) await showExtRespondSheet(ctx, roomId);
      case NickRequestEvent(:final reqId, :final fromNickname):
        final ctx = navigatorKey.currentContext;
        if (ctx == null) return;
        final accept = await showDialog<bool>(
          context: ctx,
          builder: (c) => AlertDialog(
            title: Text('$fromNickname님이 닉네임으로 연결을 요청했어요'),
            content: const Text('수락하면 지금 QR은 사라지고 대화방이 열려요.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('거절')),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('수락'),
              ),
            ],
          ),
        );
        try {
          final roomId = await state.respondNick(reqId, accept == true);
          if (roomId != null) openChat(roomId);
        } catch (err) {
          toast(err.toString());
        }
      case NickResultEvent(:final accepted, :final roomId):
        if (accepted && roomId != null) {
          toast('연결됐어요');
          openChat(roomId);
        } else {
          toast('상대가 연결 요청을 거절했어요');
        }
    }
  }

  // 로그인 전에 찍은 QR이 있으면 로그인하자마자 그 대화방으로 들어간다
  bool _joining = false;
  Future<void> _maybeJoinPending(AppState state) async {
    final code = state.pendingJoin;
    if (_joining || code == null || state.stage != Stage.ready) return;
    _joining = true;
    state.pendingJoin = null;
    try {
      final room = await state.joinFromCode(code);
      openChat(room.id);
    } catch (e) {
      toast(e.toString());
    } finally {
      _joining = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (state.stage == Stage.ready && state.pendingJoin != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeJoinPending(state));
    }
    return switch (state.stage) {
      Stage.setup => const SetupScreen(),
      Stage.loading => const LoadingScreen(),
      Stage.identity => const IdentityScreen(),
      Stage.signup => const SignupScreen(),
      Stage.blocked => const BlockedScreen(),
      Stage.ready => const HomeShell(),
    };
  }
}
