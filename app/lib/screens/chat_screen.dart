import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';
import 'detail_screen.dart';
import 'ext_sheet.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.roomId});
  final String roomId;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _timer;
  late final AppState _state;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _state.openRoomId = widget.roomId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await AppScope.read(context).loadRoom(widget.roomId);
      } catch (e) {
        toast(e.toString());
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    if (_state.openRoomId == widget.roomId) _state.openRoomId = null;
    _timer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await AppScope.read(context).send(widget.roomId, text);
    } catch (e) {
      toast(e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action, [String? done]) async {
    try {
      await action();
      if (done != null) toast(done);
    } catch (e) {
      toast(e.toString());
    }
  }

  void _openDetail() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DetailScreen(roomId: widget.roomId)));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final room = state.rooms[widget.roomId];
    final msgs = state.messages[widget.roomId] ?? const <Msg>[];

    if (msgs.length != _lastCount) {
      _lastCount = msgs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    if (room == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }

    final now = state.now;
    String timer;
    Color timerColor = p.muted;
    if (room.isLive && room.endsAt != null) {
      final left = room.endsAt! - now;
      timer = '${clockText(left)} 남음';
      timerColor = left <= 60000 ? p.warn : p.accent;
    } else {
      timer = switch (room.status) { 'pending' => '응답 대기', 'rejected' => '거절됨', _ => '종료됨' };
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _openDetail,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(room.partnerNickname, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
                  Icon(Icons.chevron_right, size: 18, color: p.muted),
                ]),
                Text(timer, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: timerColor)),
              ],
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ActionChip(
              avatar: Icon(Icons.edit_outlined, size: 16, color: p.muted),
              label: Text(memoShort(room.memo), style: TextStyle(fontSize: 13, color: p.text)),
              side: BorderSide(color: p.line),
              backgroundColor: Colors.transparent,
              shape: const StadiumBorder(),
              onPressed: _openDetail,
            ),
          ),
        ],
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Divider(height: 1, color: p.line)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Text('대화방이 열렸어요 · ${_freeLabel(state)} 무료', style: TextStyle(fontSize: 12, color: p.muted)),
                ),
                const SizedBox(height: 12),
                for (final m in msgs) _Bubble(m),
              ],
            ),
          ),
          SafeArea(top: false, child: _footer(state, room, p)),
        ],
      ),
    );
  }

  String _freeLabel(AppState s) {
    final f = s.setting('freeSeconds', 300);
    return f % 60 == 0 ? '${f ~/ 60}분' : '$f초';
  }

  Widget _footer(AppState state, Room room, Palette p) {
    final pad = const EdgeInsets.fromLTRB(16, 10, 16, 12);
    final ext = room.ext;
    final extendCost = state.setting('extendCost', 10);

    if (room.isLive) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              maxLength: 500,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(hintText: '메시지 입력', counterText: ''),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: '보내기',
            style: IconButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, minimumSize: const Size(48, 48)),
            onPressed: _send,
            icon: const Icon(Icons.arrow_upward),
          ),
        ]),
      );
    }

    if (room.status == 'ended') {
      return Padding(
        padding: pad,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('대화 시간이 끝났어요. 상대가 수락하면 연장돼요.\n거절되면 재화는 돌려받을 수 없어요.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: p.muted, height: 1.5)),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () => _run(() => state.requestExtension(room.id), '연장 요청을 보냈어요'),
            child: Text('연장 요청 보내기 · 재화 $extendCost개'),
          ),
          const SizedBox(height: 4),
          Text('보유 재화 ${state.me?.coins ?? '-'}개', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: p.muted)),
        ]),
      );
    }

    if (room.status == 'pending' && ext != null) {
      return Padding(
        padding: pad,
        child: ext.mine
            ? Text(
                '상대 응답을 기다리는 중이에요.\n${state.setting('responseTimeoutHours', 24)}시간 안에 답이 없으면 재화 ${state.setting('noResponseRefundPct', 50)}%를 돌려드려요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, height: 1.5))
            : FilledButton(onPressed: () => showExtRespondSheet(context, room.id), child: const Text('연장 요청에 응답하기')),
      );
    }

    if (room.status == 'rejected' && ext != null && ext.rejectedAt != null) {
      if (!ext.mine) {
        return Padding(
          padding: pad,
          child: Text('${hmText(ext.rejectedAt!)}에 거절했어요 · ${ext.reasonText ?? ''}', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
        );
      }
      final retryAt = ext.retryAt;
      final wait = retryAt == null ? 0 : retryAt - state.now;
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        decoration: BoxDecoration(color: p.surface, border: Border(top: BorderSide(color: p.line))),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${room.partnerNickname}님이 연장을 거절했어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(height: 2),
          Text('${hmText(ext.rejectedAt!)} · 사용한 재화는 소모됐어요', style: TextStyle(fontSize: 13, color: p.muted)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: ext.reasonLocked ? Colors.transparent : p.accentSoft,
              border: Border.all(color: ext.reasonLocked ? p.line : p.accent),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ext.reasonLocked
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Icon(Icons.lock_outline, size: 16, color: p.muted),
                      const SizedBox(width: 6),
                      Text('거절 사유', style: TextStyle(fontSize: 13, color: p.muted)),
                    ]),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _run(() => state.viewReason(room.id)),
                      child: Text('사유 보기 · 재화 ${state.setting('reasonViewCost', 3)}개'),
                    ),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('거절 사유', style: TextStyle(fontSize: 12, color: p.muted)),
                    const SizedBox(height: 4),
                    Text(ext.reasonText ?? '', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.text)),
                  ]),
          ),
          const SizedBox(height: 12),
          if (retryAt == null)
            Text('이 대화는 다시 요청할 수 없어요', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: p.muted))
          else
            FilledButton(
              onPressed: wait > 0 ? null : () => _run(() => state.requestExtension(room.id), '다시 요청했어요'),
              child: Text(wait > 0 ? '다시 요청하기 · ${clockText(wait)} 남음' : '다시 요청하기 · 재화 $extendCost개'),
            ),
        ]),
      );
    }

    return const SizedBox.shrink();
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m);
  final Msg m;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (m.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(child: Text(m.text, style: TextStyle(fontSize: 12, color: p.muted))),
      );
    }
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: m.mine ? p.mine : p.theirs,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.mine ? 18 : 6),
            bottomRight: Radius.circular(m.mine ? 6 : 18),
          ),
        ),
        child: Text(m.text, style: TextStyle(fontSize: 15, height: 1.45, color: p.text)),
      ),
    );
  }
}
