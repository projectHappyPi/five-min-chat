import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';

/// 상대 상세: 만난 시각, 연결 방식, 나만 보는 메모, 숨기기
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.roomId});
  final String roomId;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final TextEditingController _memo;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final room = AppScope.read(context).rooms[widget.roomId];
    _memo = TextEditingController(text: room?.memo ?? '');
  }

  @override
  void dispose() {
    _memo.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await AppScope.read(context).setMemo(widget.roomId, _memo.text);
      setState(() => _dirty = false);
      toast('메모를 저장했어요');
    } catch (e) {
      toast(e.toString());
    }
  }

  Future<void> _toggleHidden(Room room) async {
    try {
      await AppScope.read(context).setHidden(room.id, !room.hidden);
      toast(room.hidden ? '숨김을 해제했어요' : '대화를 숨겼어요. 목록의 숨긴 대화에서 볼 수 있어요');
    } catch (e) {
      toast(e.toString());
    }
  }

  Future<void> _report(Room room) async {
    final state = AppScope.read(context);
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReportSheet(roomId: room.id, reasons: state.reportReasons),
    );
    if (sent == true) toast('신고했어요. 관리자가 확인할게요');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final room = state.rooms[widget.roomId];
    if (room == null) return Scaffold(appBar: AppBar());
    final created = DateTime.fromMillisecondsSinceEpoch(room.createdAt);
    final status = switch (room.status) {
      'live' => '진행 중',
      'extended' => '연장됨',
      'pending' => '연장 응답 대기',
      'rejected' => '연장 거절됨',
      _ => '종료됨',
    };

    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            Text(k, style: TextStyle(color: p.muted)),
            const Spacer(),
            Text(v, style: TextStyle(color: p.text)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: p.accentSoft,
              foregroundColor: p.accent,
              child: Text(room.partnerNickname.characters.first, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
          Center(child: Text(room.partnerNickname, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: p.text))),
          Center(child: Text('만났을 때 닉네임이에요', style: TextStyle(fontSize: 13, color: p.muted))),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(color: p.surface, border: Border.all(color: p.line), borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              row('연결한 시각', '${created.month}월 ${created.day}일 ${hmText(room.createdAt)}'),
              Divider(height: 1, color: p.line),
              row('연결 방식', room.via == 'qr' ? 'QR' : '닉네임'),
              Divider(height: 1, color: p.line),
              row('대화 상태', status),
            ]),
          ),
          const SizedBox(height: 24),
          Row(children: [
            Text('메모', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.text)),
            const Spacer(),
            Text('나만 볼 수 있어요', style: TextStyle(fontSize: 12, color: p.muted)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _memo,
            maxLength: 100,
            minLines: 3,
            maxLines: 5,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(hintText: '이 사람에 대해 기억하고 싶은 걸 적어두세요'),
          ),
          Text('앞 7글자가 대화방 오른쪽 위에 보여요: ${memoShort(_memo.text)}', style: TextStyle(fontSize: 12, color: p.muted)),
          const SizedBox(height: 12),
          FilledButton(onPressed: _dirty ? _save : null, child: Text(_dirty ? '메모 저장' : '저장됨')),
          const SizedBox(height: 28),
          Divider(height: 1, color: p.line),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(room.hidden ? '숨김 해제' : '대화 숨기기', style: TextStyle(color: p.text)),
            onTap: () => _toggleHidden(room),
          ),
          Divider(height: 1, color: p.line),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(room.reported ? '신고 접수됨' : '신고하기', style: TextStyle(color: room.reported ? p.muted : p.danger)),
            subtitle: Text('관리자가 대화 내용을 확인해요', style: TextStyle(fontSize: 12, color: p.muted)),
            onTap: room.reported ? null : () => _report(room),
          ),
        ],
      ),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.roomId, required this.reasons});
  final String roomId;
  final List<String> reasons;
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _reason;
  final _detail = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _send() async {
    if (_reason == null) {
      setState(() => _error = '신고 사유를 골라 주세요');
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.read(context).report(widget.roomId, _reason!, _detail.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('신고하기', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: p.text)),
            const SizedBox(height: 4),
            Text('관리자가 대화 내용을 확인해요. 신고한 대화는 내 목록에서 숨겨져요.', style: TextStyle(fontSize: 13, color: p.muted)),
            const SizedBox(height: 12),
            for (final r in widget.reasons)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(r == _reason ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: r == _reason ? p.accent : p.muted),
                title: Text(r, style: TextStyle(color: p.text)),
                onTap: () => setState(() => _reason = r),
              ),
            TextField(controller: _detail, maxLength: 300, maxLines: 3, decoration: const InputDecoration(hintText: '자세한 내용 (선택)')),
            const SizedBox(height: 8),
            FilledButton(onPressed: _busy ? null : _send, child: const Text('신고하기')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: p.danger))),
          ],
        ),
      ),
    );
  }
}
