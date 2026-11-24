import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../translator.dart';

/// 번역 언어 팩 관리: 미리 받아 두거나 지우기
class LangPacksScreen extends StatefulWidget {
  const LangPacksScreen({super.key});
  @override
  State<LangPacksScreen> createState() => _LangPacksScreenState();
}

class _LangPacksScreenState extends State<LangPacksScreen> {
  final _t = Translator.instance;
  final _input = TextEditingController(text: '안녕하세요! 아까 카페에서 만났던 사람이에요.');
  String _from = 'ko';
  String _to = 'en';
  String? _out;
  int? _ms;
  bool _wifiOnly = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(_changed);
    _t.refreshAll();
  }

  @override
  void dispose() {
    _t.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  Future<void> _download(Lang l) async {
    try {
      final ok = await _t.download(l.code, wifiOnly: _wifiOnly);
      toast(ok ? '${l.koName} 언어 팩을 받았어요' : '받지 못했어요${_wifiOnly ? ' (와이파이에 연결해 주세요)' : ''}');
    } catch (e) {
      toast('받지 못했어요: $e');
    }
  }

  Future<void> _delete(Lang l) async {
    try {
      await _t.delete(l.code);
    } catch (e) {
      toast(e.toString());
    }
  }

  Future<void> _try() async {
    final missing = await _t.missing(_from, _to);
    if (missing.isNotEmpty) {
      toast('${missing.map((c) => langOf(c)?.koName ?? c).join(', ')} 언어 팩을 먼저 받아 주세요');
      return;
    }
    final sw = Stopwatch()..start();
    try {
      final out = await _t.translate(_input.text, from: _from, to: _to);
      setState(() {
        _out = out;
        _ms = sw.elapsedMilliseconds;
      });
    } catch (e) {
      toast(e.toString());
    }
  }

  DropdownButton<String> _langDrop(String value, ValueChanged<String> onChanged) => DropdownButton<String>(
        value: value,
        items: [for (final l in kLangs) DropdownMenuItem(value: l.code, child: Text(l.koName))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('번역 언어 팩')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('Google ML Kit 번역을 써요. 언어 팩은 언어당 약 30MB이고, 받은 뒤에는 인터넷 없이 폰 안에서 번역해요. 영어는 기본으로 들어 있어요.',
              style: TextStyle(fontSize: 13, color: p.muted, height: 1.5)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('와이파이에서만 받기'),
            value: _wifiOnly,
            onChanged: (v) => setState(() => _wifiOnly = v),
          ),
          const Divider(),
          for (final l in kLangs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.label),
              trailing: _t.downloading.contains(l.code)
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : switch (_t.isDownloadedCached(l.code)) {
                      null => const SizedBox(width: 22),
                      true => l.code == 'en'
                          ? Text('기본', style: TextStyle(color: p.muted))
                          : TextButton(onPressed: () => _delete(l), child: Text('지우기', style: TextStyle(color: p.muted))),
                      false => FilledButton.tonal(onPressed: () => _download(l), child: const Text('받기')),
                    },
              leading: Icon(_t.isDownloadedCached(l.code) == true ? Icons.check_circle : Icons.download_outlined,
                  color: _t.isDownloadedCached(l.code) == true ? p.accent : p.muted),
            ),
          const Divider(height: 32),
          Text('번역해 보기', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(height: 8),
          TextField(controller: _input, minLines: 2, maxLines: 4),
          Row(children: [
            _langDrop(_from, (v) => setState(() => _from = v)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 18)),
            _langDrop(_to, (v) => setState(() => _to = v)),
            const Spacer(),
            FilledButton(onPressed: _try, child: const Text('번역')),
          ]),
          if (_out != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(_out!, style: TextStyle(fontSize: 15, height: 1.5, color: p.text)),
            ),
            const SizedBox(height: 4),
            Text('${_ms}ms 걸림', style: TextStyle(fontSize: 12, color: p.muted)),
          ],
        ],
      ),
    );
  }
}
