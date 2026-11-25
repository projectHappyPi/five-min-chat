import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';
import '../translator.dart';

/// 언어 고르기 (대화방에 처음 들어올 때, 또는 번역 설정에서 바꿀 때)
Future<String?> pickLanguage(BuildContext context, {required String initial, String? partnerLang, bool first = false}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: !first,
    enableDrag: !first,
    showDragHandle: true,
    builder: (c) {
      var selected = initial;
      final p = c.pal;
      return StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.85),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(first ? '이 대화에서 쓸 내 언어를 골라 주세요' : '내 언어 바꾸기',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    partnerLang == null
                        ? 'Choose the language you will use in this chat. 상대도 자기 언어를 고르면 번역을 켤 수 있어요.'
                        : 'Choose your language. 상대 언어: ${langOf(partnerLang)?.label ?? partnerLang}',
                    style: TextStyle(fontSize: 13, color: p.muted, height: 1.4),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final l in kLangs)
                        ListTile(
                          title: Text(l.label),
                          trailing: l.code == selected ? Icon(Icons.check_circle, color: p.accent) : const Icon(Icons.circle_outlined),
                          onTap: () => set(() => selected = l.code),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: FilledButton(onPressed: () => Navigator.pop(c, selected), child: const Text('확인 · OK')),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 번역에 필요한 언어 팩이 없으면 받을지 묻고 받는다. 다 준비되면 true
Future<bool> ensurePacks(BuildContext context, List<String> codes) async {
  final t = Translator.instance;
  final need = <String>[];
  for (final c in codes.toSet()) {
    if (!await t.isDownloaded(c)) need.add(c);
  }
  if (need.isEmpty) return true;
  if (!context.mounted) return false;
  final names = need.map((c) => langOf(c)?.koName ?? c).join(', ');
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('번역 언어 팩 받기'),
      content: Text('$names 언어 팩이 필요해요 (언어당 약 30MB).\n한 번 받으면 인터넷 없이 폰 안에서 번역해요.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('나중에')),
        FilledButton(style: compactButton, onPressed: () => Navigator.pop(c, true), child: const Text('받기')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(children: [
        const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(width: 16),
        Expanded(child: Text('$names 언어 팩 받는 중…')),
      ]),
    ),
  );
  var all = true;
  try {
    for (final c in need) {
      if (!await t.download(c)) all = false;
    }
  } catch (e) {
    all = false;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  toast(all ? '언어 팩을 받았어요' : '언어 팩을 받지 못했어요. 인터넷 연결을 확인해 주세요');
  return all;
}

/// 대화방의 번역 켜기·끄기와 언어 설정
Future<void> showTranslateSheet(BuildContext context, String roomId) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (c) => _TranslateSheet(roomId: roomId),
  );
}

class _TranslateSheet extends StatelessWidget {
  const _TranslateSheet({required this.roomId});
  final String roomId;

  Future<void> _toggle(BuildContext context, AppState state, Room room, bool on) async {
    if (on) {
      final my = room.myLang, partner = room.partnerLang;
      if (my == null) {
        toast('먼저 내 언어를 골라 주세요');
        return;
      }
      if (!await ensurePacks(context, [my, if (partner != null) partner])) return;
    }
    await state.setTranslate(roomId, on);
    if (on && room.partnerLang == null) toast('상대가 언어를 고르면 그때부터 번역돼요');
  }

  Future<void> _changeLang(BuildContext context, AppState state, Room room) async {
    final l = await pickLanguage(context, initial: room.myLang ?? state.me?.lang ?? deviceLangCode(), partnerLang: room.partnerLang);
    if (l == null) return;
    try {
      await state.setRoomLang(roomId, l);
      if (state.translateOn(roomId) && context.mounted) {
        await ensurePacks(context, [l, if (room.partnerLang != null) room.partnerLang!]);
      }
    } catch (e) {
      toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final room = state.rooms[roomId];
    if (room == null) return const SizedBox.shrink();
    final on = state.translateOn(roomId);
    final same = room.myLang != null && room.myLang == room.partnerLang;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('번역', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(height: 4),
          Text('켜면 내가 보내는 말은 상대 언어로, 상대가 보낸 말은 내 언어로 자동 번역돼요. 번역은 폰 안에서 처리돼요.',
              style: TextStyle(fontSize: 13, color: p.muted, height: 1.45)),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('자동 번역'),
            subtitle: same ? const Text('두 사람 언어가 같아서 번역할 게 없어요') : null,
            value: on,
            onChanged: (v) => _toggle(context, state, room, v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('내 언어'),
            subtitle: Text(langOf(room.myLang)?.label ?? '아직 안 골랐어요'),
            trailing: TextButton(onPressed: () => _changeLang(context, state, room), child: const Text('바꾸기')),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('상대 언어'),
            subtitle: Text(langOf(room.partnerLang)?.label ?? '상대가 아직 안 골랐어요'),
          ),
        ]),
      ),
    );
  }
}
