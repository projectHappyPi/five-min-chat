import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';

/// 내 이모지 고르기: 기본 20개 + 재화로 사는 상점 이모지 + 관리자에게 신청
Future<void> showEmojiSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _EmojiSheet(),
  );
}

class _EmojiSheet extends StatefulWidget {
  const _EmojiSheet();
  @override
  State<_EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<_EmojiSheet> {
  EmojiCatalog? _c;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await AppScope.read(context).emojiList();
      if (mounted) setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<EmojiCatalog> Function() f, [String? done]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final c = await f();
      if (mounted) setState(() => _c = c);
      if (done != null) toast(done);
    } catch (e) {
      toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buy(ShopEmoji e) async {
    final state = AppScope.read(context);
    if (e.owned) return _run(() => state.setEmoji(e.emoji));
    final coins = state.me?.coins ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${e.emoji} 이모지 사기'),
        content: Text('재화 ${e.price}개를 써요. (보유 $coins개)\n산 이모지는 언제든 다시 쓸 수 있어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(style: compactButton, onPressed: coins < e.price ? null : () => Navigator.pop(c, true), child: const Text('사기')),
        ],
      ),
    );
    if (ok == true) await _run(() => state.buyEmoji(e.id), '${e.emoji} 이모지로 바꿨어요');
  }

  Future<void> _request() async {
    final emoji = TextEditingController();
    final note = TextEditingController();
    final sent = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('이모지 신청'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('갖고 싶은 이모지를 관리자에게 신청해요. 승인되면 상점에 올라가거나 선물로 받을 수 있어요.', style: TextStyle(fontSize: 13, height: 1.45)),
          const SizedBox(height: 12),
          TextField(controller: emoji, maxLength: 16, decoration: const InputDecoration(labelText: '이모지 (선택)', hintText: '🐙', counterText: '')),
          const SizedBox(height: 8),
          TextField(controller: note, maxLength: 200, maxLines: 3, minLines: 2, decoration: const InputDecoration(labelText: '설명', hintText: '예) 왕관 쓴 고양이')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(style: compactButton, onPressed: () => Navigator.pop(c, true), child: const Text('신청')),
        ],
      ),
    );
    if (sent == true && mounted) {
      await _run(() => AppScope.read(context).requestEmoji(emoji.text.trim(), note.text.trim()), '신청했어요. 결과는 여기에서 볼 수 있어요');
    }
    emoji.dispose();
    note.dispose();
  }

  Widget _cell(Palette p, String emoji, {required bool selected, String? caption, bool locked = false, VoidCallback? onTap}) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$emoji${caption != null ? ' $caption' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _busy ? null : onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? p.accentSoft : Colors.transparent,
            border: Border.all(color: selected ? p.accent : p.line, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Opacity(opacity: locked ? 0.55 : 1, child: Text(emoji, style: const TextStyle(fontSize: 28))),
            if (caption != null) Text(caption, style: TextStyle(fontSize: 11, color: locked ? p.muted : p.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Widget _grid(List<Widget> cells) => GridView.count(
        crossAxisCount: 5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.95,
        children: cells,
      );

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final state = AppScope.of(context);
    final c = _c;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: c == null
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: _error != null ? Text(_error!, style: TextStyle(color: p.danger)) : const CircularProgressIndicator()),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  Row(children: [
                    Text(c.current, style: const TextStyle(fontSize: 40)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('내 이모지', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
                        Text('QR 위와 상대 대화 목록에 보여요 · 재화 ${state.me?.coins ?? '-'}개', style: TextStyle(fontSize: 13, color: p.muted)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Text('기본', style: TextStyle(fontWeight: FontWeight.w700, color: p.text)),
                  const SizedBox(height: 8),
                  _grid([
                    for (final e in c.free) _cell(p, e, selected: e == c.current, onTap: () => _run(() => state.setEmoji(e))),
                  ]),
                  const SizedBox(height: 20),
                  Text('상점', style: TextStyle(fontWeight: FontWeight.w700, color: p.text)),
                  const SizedBox(height: 8),
                  _grid([
                    for (final e in c.shop)
                      _cell(p, e.emoji,
                          selected: e.emoji == c.current, caption: e.owned ? '보유' : '${e.price}', locked: !e.owned, onTap: () => _buy(e)),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(child: Text('이모지 신청', style: TextStyle(fontWeight: FontWeight.w700, color: p.text))),
                    TextButton.icon(onPressed: _request, icon: const Icon(Icons.add), label: const Text('신청하기')),
                  ]),
                  if (c.requests.isEmpty)
                    Text('원하는 이모지가 없으면 신청해 주세요.', style: TextStyle(fontSize: 13, color: p.muted))
                  else
                    for (final r in c.requests)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Text(r.emoji ?? '✉️', style: const TextStyle(fontSize: 24)),
                        title: Text(r.note.isEmpty ? '(설명 없음)' : r.note, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: r.answer != null ? Text(r.answer!) : null,
                        trailing: Text(r.statusLabel,
                            style: TextStyle(fontWeight: FontWeight.w600, color: r.status == 'approved' ? p.accent : p.muted)),
                      ),
                ],
              ),
      ),
    );
  }
}
