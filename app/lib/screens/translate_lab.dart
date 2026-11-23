import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';
import '../translator.dart';

const _langs = <String, String>{
  'Korean': '한국어',
  'English': '영어',
  'Japanese': '일본어',
  'Chinese': '중국어',
  'Vietnamese': '베트남어',
  'Thai': '태국어',
  'Spanish': '스페인어',
  'French': '프랑스어',
};

const _samples = <String>[
  '안녕하세요! 아까 카페에서 만났던 사람이에요.',
  '혹시 이 근처에 맛있는 식당 아세요?',
  'Nice to meet you. Are you from around here?',
  'はじめまして。韓国は初めてです。',
];

/// 통역 모델을 내려받아 폰에서 직접 번역 속도·품질을 확인하는 화면
class TranslateLabScreen extends StatefulWidget {
  const TranslateLabScreen({super.key});
  @override
  State<TranslateLabScreen> createState() => _TranslateLabScreenState();
}

class _TranslateLabScreenState extends State<TranslateLabScreen> {
  final _t = Translator.instance;
  final _input = TextEditingController(text: _samples.first);
  final Map<String, List<ModelFile>?> _files = {};
  final Map<String, String> _listErrors = {};
  ModelFile? _last;
  String _target = 'English';
  String? _output;
  int? _millis;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _t.addListener(_changed);
    Translator.lastUsed().then((f) => mounted ? setState(() => _last = f) : null);
    for (final r in kModelRepos) {
      _loadList(r);
    }
  }

  @override
  void dispose() {
    _t.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  Future<void> _loadList(ModelRepo r) async {
    try {
      final files = await Translator.listFiles(r);
      if (mounted) setState(() => _files[r.repoId] = files);
    } catch (e) {
      if (mounted) setState(() => _listErrors[r.repoId] = e.toString());
    }
  }

  Future<void> _download(ModelFile f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${f.repo.title} 받기'),
        content: Text('${f.path}\n${f.sizeLabel}\n\n와이파이에서 받는 걸 권장해요. 이미 받은 파일이면 다운로드 없이 바로 열어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('받기')),
        ],
      ),
    );
    if (ok != true) return;
    await _t.load(f);
    if (_t.error != null) {
      toast(_t.error!);
    } else {
      toast('모델 준비 완료');
      setState(() => _last = f);
    }
  }

  Future<void> _translate() async {
    final text = _input.text.trim();
    if (text.isEmpty || !_t.ready) return;
    setState(() {
      _running = true;
      _output = null;
      _millis = null;
    });
    try {
      final r = await _t.translate(text, target: _target);
      setState(() {
        _output = r.text;
        _millis = r.millis;
      });
    } catch (e) {
      toast(e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('통역 모델 시험')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _statusCard(p),
          const SizedBox(height: 16),
          if (_t.ready) ...[
            _tryCard(p),
            const SizedBox(height: 24),
          ],
          Text('모델 고르기', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
          const SizedBox(height: 4),
          Text('파일 이름의 Q4·Q8 같은 숫자가 작을수록 가볍고 빠르지만 품질이 조금 떨어져요. 처음엔 Hy-MT2의 Q4_K_M을 추천해요.',
              style: TextStyle(fontSize: 13, color: p.muted, height: 1.5)),
          const SizedBox(height: 12),
          for (final r in kModelRepos) _repoCard(r, p),
        ],
      ),
    );
  }

  Widget _statusCard(Palette p) {
    final busy = _t.busyKey != null;
    String title;
    String sub;
    if (busy) {
      title = '준비 중…';
      final mb = (_t.receivedBytes / 1e6).round();
      sub = _t.progress == null
          ? (mb > 0 ? '$mb MB 받음' : '파일 확인·모델 여는 중')
          : '${(_t.progress! * 100).toStringAsFixed(0)}% · $mb MB';
    } else if (_t.ready) {
      title = '모델 준비됨';
      sub = _t.loadedKey ?? '';
    } else {
      title = '모델 없음';
      sub = '아래에서 모델을 받아 주세요';
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border.all(color: _t.ready ? p.accent : p.line), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        const SizedBox(height: 4),
        Text(sub, style: TextStyle(fontSize: 13, color: p.muted)),
        if (busy) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: _t.progress),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _t.cancel, child: const Text('취소'))),
        ],
        if (!busy && !_t.ready && _last != null) ...[
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => _t.load(_last!), child: Text('지난번 모델 다시 열기 · ${_last!.repo.title}')),
        ],
        if (_t.ready) ...[
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _t.unload, child: const Text('메모리에서 내리기'))),
        ],
        if (_t.error != null && !busy) ...[
          const SizedBox(height: 8),
          Text(_t.error!, style: TextStyle(fontSize: 13, color: p.danger)),
        ],
      ]),
    );
  }

  Widget _tryCard(Palette p) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('번역해 보기', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.text)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final s in _samples)
          ActionChip(
            label: Text(s.length > 14 ? '${s.substring(0, 14)}…' : s, style: const TextStyle(fontSize: 12)),
            onPressed: () => setState(() {
              _input.text = s;
              _target = Translator.autoTarget(s);
            }),
          ),
      ]),
      const SizedBox(height: 8),
      TextField(controller: _input, minLines: 2, maxLines: 5, decoration: const InputDecoration(hintText: '번역할 문장')),
      const SizedBox(height: 8),
      Row(children: [
        Text('번역할 언어', style: TextStyle(color: p.muted)),
        const SizedBox(width: 12),
        DropdownButton<String>(
          value: _target,
          items: [for (final e in _langs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _target = v ?? _target),
        ),
        const Spacer(),
        FilledButton(onPressed: _running ? null : _translate, child: Text(_running ? '번역 중…' : '번역')),
      ]),
      if (_output != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(12)),
          child: SelectableText(_output!, style: TextStyle(fontSize: 15, height: 1.5, color: p.text)),
        ),
        const SizedBox(height: 6),
        Text('${(_millis! / 1000).toStringAsFixed(1)}초 걸림 (첫 번역은 조금 더 느려요)', style: TextStyle(fontSize: 12, color: p.muted)),
      ],
    ]);
  }

  Widget _repoCard(ModelRepo r, Palette p) {
    final files = _files[r.repoId];
    final err = _listErrors[r.repoId];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border.all(color: r.recommended ? p.accent : p.line), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(r.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.text))),
          if (r.recommended)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(8)),
              child: Text('추천', style: TextStyle(fontSize: 12, color: p.onAccent, fontWeight: FontWeight.w700)),
            ),
        ]),
        const SizedBox(height: 4),
        Text(r.note, style: TextStyle(fontSize: 13, color: r.mayFail ? p.warn : p.muted, height: 1.4)),
        const SizedBox(height: 8),
        if (err != null)
          Row(children: [
            Expanded(child: Text('목록을 못 불러왔어요', style: TextStyle(fontSize: 13, color: p.muted))),
            TextButton(
              onPressed: () {
                setState(() => _listErrors.remove(r.repoId));
                _loadList(r);
              },
              child: const Text('다시'),
            ),
          ])
        else if (files == null)
          const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
        else if (files.isEmpty)
          Text('받을 수 있는 파일이 없어요', style: TextStyle(fontSize: 13, color: p.muted))
        else
          for (final f in files)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(f.path, style: TextStyle(fontSize: 13, color: p.text)),
              subtitle: Text(f.sizeLabel, style: TextStyle(fontSize: 12, color: p.muted)),
              trailing: _t.loadedKey == f.key
                  ? Icon(Icons.check_circle, color: p.accent)
                  : TextButton(onPressed: _t.busyKey != null ? null : () => _download(f), child: const Text('받기')),
            ),
      ]),
    );
  }
}
