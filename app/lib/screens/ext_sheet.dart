import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';

/// 상대의 연장 요청에 응답: 수락하거나, 사유를 골라(필수) 거절한다.
Future<void> showExtRespondSheet(BuildContext context, String roomId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ExtRespondSheet(roomId: roomId),
  );
}

class _ExtRespondSheet extends StatefulWidget {
  const _ExtRespondSheet({required this.roomId});
  final String roomId;
  @override
  State<_ExtRespondSheet> createState() => _ExtRespondSheetState();
}

class _ExtRespondSheetState extends State<_ExtRespondSheet> {
  String? _reasonId;
  final _custom = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit(bool accept) async {
    final state = AppScope.read(context);
    if (!accept && _reasonId == null) {
      setState(() => _error = '거절 사유를 골라 주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.respondExtension(widget.roomId, accept: accept, reasonId: _reasonId, reasonText: _custom.text);
      if (!mounted) return;
      Navigator.pop(context);
      toast(accept ? '대화가 연장됐어요' : '거절했어요');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final room = state.rooms[widget.roomId];
    Reason? selected;
    for (final r in state.reasons) {
      if (r.id == _reasonId) selected = r;
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${room?.partnerNickname ?? '상대'}님이 대화를 더 하고 싶어해요',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: p.text)),
            if (room?.ext != null) ...[
              const SizedBox(height: 4),
              Text('${hmText(room!.ext!.respondBy)}까지 답하지 않으면 요청이 만료돼요', style: TextStyle(fontSize: 13, color: p.muted)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : () => _submit(true), child: const Text('수락하고 대화 이어가기')),
            const SizedBox(height: 18),
            Text('거절하려면 사유를 골라주세요 (필수)', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: p.muted)),
            const SizedBox(height: 8),
            for (final r in state.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: r.id == _reasonId ? p.accentSoft : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: r.id == _reasonId ? p.accent : p.line, width: r.id == _reasonId ? 2 : 1),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _reasonId = r.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          Icon(r.id == _reasonId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                              size: 20, color: r.id == _reasonId ? p.accent : p.muted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(r.text, style: TextStyle(fontSize: 15, color: p.text))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (selected?.custom == true)
              TextField(
                controller: _custom,
                maxLength: 100,
                maxLines: 2,
                decoration: const InputDecoration(hintText: '사유를 직접 입력해 주세요'),
              ),
            Text('거절 시각은 상대에게 바로 보여요. 사유는 상대가 재화를 써야 볼 수 있어요.', style: TextStyle(fontSize: 12, color: p.muted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : () => _submit(false), child: const Text('거절하기')),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: p.danger)),
            ],
          ],
        ),
      ),
    );
  }
}
