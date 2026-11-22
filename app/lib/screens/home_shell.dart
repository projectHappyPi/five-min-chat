import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';
import 'scanner_view.dart';

/// 하단 탭: 내 QR(홈) / 스캔 / 대화
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final unread = state.totalUnread;
    return Scaffold(
      body: SafeArea(
        child: switch (_tab) {
          0 => const QrTab(),
          // 스캔 탭을 떠나면 카메라를 끄도록 탭을 고를 때만 만든다
          1 => const ScanTab(),
          _ => const ListTab(),
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.qr_code_2), label: '내 QR'),
          const NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: '스캔'),
          NavigationDestination(
            icon: Badge(isLabelVisible: unread > 0, label: Text(unread > 99 ? '99+' : '$unread'), child: const Icon(Icons.chat_bubble_outline)),
            label: '대화',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 내 QR

class QrTab extends StatefulWidget {
  const QrTab({super.key});
  @override
  State<QrTab> createState() => _QrTabState();
}

class _QrTabState extends State<QrTab> {
  Timer? _timer;
  bool _renewing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureQr());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _ensureQr();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // QR이 없거나 만료되면 알아서 새로 만든다
  Future<void> _ensureQr() async {
    final state = AppScope.read(context);
    if (_renewing || !state.connected) return;
    final qr = state.qr;
    if (qr != null && qr.expiresAt > state.now) return;
    _renewing = true;
    try {
      await state.newQr();
    } catch (_) {
      // 다음 틱에 다시 시도
    } finally {
      _renewing = false;
    }
  }

  Future<void> _reroll() async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('닉네임 다시 뽑기'),
        content: Text('재화 ${state.setting('rerollCost', 5)}개를 써서 새 닉네임을 받을까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('다시 뽑기')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.reroll();
      toast('새 닉네임: ${state.me?.nickname}');
    } catch (e) {
      toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final qr = state.qr;
    final total = state.setting('qrSeconds', 600) * 1000;
    final left = qr == null ? 0 : qr.expiresAt - state.now;
    final renewed = DateTime.now().millisecondsSinceEpoch - state.qrRenewedAt < 4000;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('이번 주 내 닉네임', style: TextStyle(fontSize: 12, color: p.muted)),
                    Text(state.me?.nickname ?? '-', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: p.text)),
                  ],
                ),
              ),
              Text(
                state.me == null ? '' : '${state.me!.genderLabel} · 만 ${state.me!.age}세 · 재화 ${state.me!.coins}',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
              PopupMenuButton<String>(
                tooltip: '더보기',
                onSelected: (v) {
                  if (v == 'reroll') _reroll();
                  if (v == 'server') state.resetServer();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'reroll', child: Text('닉네임 다시 뽑기')),
                  PopupMenuItem(value: 'server', child: Text('서버 주소 바꾸기')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                  child: SizedBox(
                    width: 250,
                    height: 250,
                    child: qr == null
                        ? const Center(child: CircularProgressIndicator())
                        : QrImageView(
                            data: qr.url,
                            backgroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                          ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  qr == null ? '--:--' : clockText(left),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.accent),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 250,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: qr == null ? 0 : (left / total).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: p.line,
                      color: p.accent,
                    ),
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: renewed ? Padding(padding: const EdgeInsets.only(top: 8), child: Text('새 QR로 바뀌었어요', style: TextStyle(fontSize: 12, color: p.muted))) : null,
                ),
                if (!state.connected) Text('서버 연결이 끊겼어요. 다시 연결하는 중…', style: TextStyle(color: p.danger, fontSize: 13)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 스캔

class ScanTab extends StatelessWidget {
  const ScanTab({super.key});

  Future<void> _nickname(BuildContext context) async {
    final state = AppScope.read(context);
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('닉네임으로 연결'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '상대 닉네임'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('요청 보내기')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await state.connectNickname(name);
      toast('요청을 보냈어요. 상대가 수락하면 대화방이 열려요');
    } catch (e) {
      toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: ScannerView(onCode: (code) async {
              try {
                final room = await state.joinFromCode(code);
                if (state.lastJoinReused) toast('이미 대화한 상대예요. 기존 대화방을 열었어요');
                openChat(room.id);
              } catch (e) {
                toast(e.toString());
              }
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => _nickname(context),
            child: const Text('닉네임으로 연결'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 대화목록

class ListTab extends StatefulWidget {
  const ListTab({super.key});
  @override
  State<ListTab> createState() => _ListTabState();
}

class _ListTabState extends State<ListTab> {
  Timer? _timer;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static const _order = {'live': 0, 'extended': 0, 'pending': 1, 'ended': 2, 'rejected': 2};

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final rooms = state.rooms.values.where((r) => r.status != 'expired' && r.hidden == _showHidden).toList()
      ..sort((a, b) {
        final o = (_order[a.status] ?? 3).compareTo(_order[b.status] ?? 3);
        if (o != 0) return o;
        return (b.lastAt ?? b.createdAt).compareTo(a.lastAt ?? a.createdAt);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text(_showHidden ? '숨긴 대화' : '대화', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: p.text))),
              IconButton(
                tooltip: _showHidden ? '대화 목록' : '숨긴 대화',
                onPressed: () => setState(() => _showHidden = !_showHidden),
                icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off_outlined, color: p.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: rooms.isEmpty
              ? Center(child: Text(_showHidden ? '숨긴 대화가 없어요' : '아직 대화가 없어요', style: TextStyle(color: p.muted)))
              : ListView.builder(
                  itemCount: rooms.length,
                  itemBuilder: (_, i) => _RoomTile(room: rooms[i], now: state.now),
                ),
        ),
      ],
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.room, required this.now});
  final Room room;
  final int now;

  String get _preview {
    final e = room.ext;
    if (room.status == 'rejected' && e != null && e.rejectedAt != null) {
      return '${hmText(e.rejectedAt!)}에 연장${e.mine ? '이 거절됐어요' : '을 거절했어요'}';
    }
    if (room.status == 'pending' && e != null) return e.mine ? '상대 응답을 기다리는 중' : '연장 요청이 왔어요';
    return room.lastText ?? '대화방이 열렸어요';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget badge;
    if (room.isLive && room.endsAt != null) {
      final left = room.endsAt! - now;
      final warn = left <= 60000;
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: warn ? p.warn : p.accent, borderRadius: BorderRadius.circular(8)),
        child: Text(clockText(left), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: warn ? p.onWarn : p.onAccent)),
      );
    } else {
      final label = switch (room.status) {
        'pending' => '응답 대기',
        'rejected' => '거절됨',
        _ => '연장 가능 ${(((room.windowEnd ?? now) - now) / 3600000).floor()}시간',
      };
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: TextStyle(fontSize: 12, color: p.muted)),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: room.isLive ? p.accentSoft : p.surface,
        foregroundColor: room.isLive ? p.accent : p.muted,
        child: Text(room.partnerNickname.characters.first, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      title: Text(room.partnerNickname, style: TextStyle(fontWeight: FontWeight.w600, color: p.text)),
      subtitle: Text(_preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted)),
      // 카카오톡처럼 안 읽은 메시지 수를 빨간 동그라미로
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          badge,
          if (room.unread > 0) ...[
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(10)),
              child: Text(
                room.unread > 99 ? '99+' : '${room.unread}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
      onTap: () => openChat(room.id),
    );
  }
}
