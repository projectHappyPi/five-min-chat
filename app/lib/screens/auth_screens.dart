import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../kakao_auth.dart';
import '../state.dart';
import '../theme.dart';

/// 가입 단계 표시: 1 기기 인증 · 2 간편인증 · 3 가입
class _Steps extends StatelessWidget {
  const _Steps(this.current);
  final int current;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    const labels = ['기기 인증', '간편인증', '가입'];
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('·', style: TextStyle(color: p.muted))),
          Text(
            '${i + 1} ${labels[i]}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: i + 1 == current ? FontWeight.w700 : FontWeight.w400,
              color: i + 1 == current ? p.accent : (i + 1 < current ? p.text : p.muted),
            ),
          ),
        ],
      ],
    );
  }
}

/// 서버에 연결 중 (무료 서버는 깨어나는 데 1분 가까이 걸릴 수 있다)
class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.bootError == null) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text('서버에 연결하는 중이에요', style: TextStyle(color: p.text, fontSize: 16)),
                  const SizedBox(height: 6),
                  Text('오랜만이면 서버가 깨어나는 데 1분 정도 걸릴 수 있어요', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 13)),
                ] else ...[
                  Icon(Icons.wifi_off, size: 40, color: p.muted),
                  const SizedBox(height: 16),
                  Text(state.bootError!, textAlign: TextAlign.center, style: TextStyle(color: p.text)),
                  const SizedBox(height: 20),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(160, 50)),
                    onPressed: state.boot,
                    child: const Text('다시 시도'),
                  ),
                  if (kServerUrl.isEmpty)
                    TextButton(onPressed: state.resetServer, child: const Text('서버 주소 다시 입력')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 2단계: 간편인증. 테스트 버전은 PASS·카카오 인증창 대신 직접 입력한다.
class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final _name = TextEditingController();
  final _birth = TextEditingController();
  final _phone = TextEditingController();
  String? _gender;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_gender == null) {
      setState(() => _error = '성별을 골라 주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).verifyIdentity(name: _name.text, birth: _birth.text, gender: _gender!, phone: _phone.text);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- 카카오로 시작하기
  Future<void> _kakao() async {
    if (!kakaoReady) return _kakaoTest();
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.read(context);
    try {
      final token = await kakaoLogin();
      if (token == null) return; // 사용자가 취소
      try {
        await state.verifyKakao(accessToken: token);
      } on ApiError catch (e) {
        if (e.code != 'kakao_scope') rethrow;
        // 성별·생년월일 제공에 동의하지 않았으면 그 항목만 다시 물어본다
        final again = await kakaoAskBirthGender();
        if (again == null) throw ApiError('kakao_scope', '가입하려면 카카오에서 성별·출생연도·생일 제공에 동의해 주세요');
        await state.verifyKakao(accessToken: again);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 앱에 카카오 키가 아직 없을 때: 카카오가 돌려줄 정보를 직접 넣어 흐름을 시험한다
  Future<void> _kakaoTest() async {
    final id = TextEditingController();
    final year = TextEditingController();
    final mmdd = TextEditingController();
    String? g;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('카카오 가입 (테스트)'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('카카오 앱 키를 넣기 전이라 카카오가 알려 줄 정보를 직접 입력해요. 같은 회원번호로 다시 하면 같은 계정으로 로그인돼요.',
                  style: TextStyle(fontSize: 13, height: 1.45)),
              const SizedBox(height: 12),
              TextField(
                controller: id,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(15)],
                decoration: const InputDecoration(labelText: '카카오 회원번호 (아무 숫자)', hintText: '1234567'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: year,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                decoration: const InputDecoration(labelText: '출생연도', hintText: '1995'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: mmdd,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                decoration: const InputDecoration(labelText: '생일 (월일 4자리)', hintText: '0314'),
              ),
              const SizedBox(height: 12),
              Row(children: [
                for (final (v, label) in [('male', '남성'), ('female', '여성')]) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        backgroundColor: g == v ? c.pal.accentSoft : Colors.transparent,
                        side: BorderSide(color: g == v ? c.pal.accent : c.pal.line, width: g == v ? 2 : 1),
                      ),
                      onPressed: () => set(() => g = v),
                      child: Text(label),
                    ),
                  ),
                  if (v == 'male') const SizedBox(width: 8),
                ],
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
            FilledButton(style: compactButton, onPressed: () => Navigator.pop(c, true), child: const Text('카카오로 가입')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).verifyKakao(mock: {
        'kakaoId': id.text,
        'birthyear': year.text,
        'birthday': mmdd.text,
        'gender': g,
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget gender(String value, String label) {
      final on = _gender == value;
      return Expanded(
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: on ? p.accentSoft : Colors.transparent,
            side: BorderSide(color: on ? p.accent : p.line, width: on ? 2 : 1),
            minimumSize: const Size.fromHeight(50),
          ),
          onPressed: () => setState(() => _gender = value),
          child: Text(label),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            const _Steps(2),
            const SizedBox(height: 20),
            Text('간편인증', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: p.text)),
            const SizedBox(height: 8),
            Text(
              '나이와 성별을 확인하려고 본인 인증을 해요. 만 19세 이상만 쓸 수 있어요.\n'
              '테스트 버전이라 PASS·카카오 인증창 대신 직접 입력해요. 같은 정보로 다시 인증하면 같은 계정으로 로그인돼요.',
              style: TextStyle(color: p.muted, height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 20),
            // 카카오 공식 버튼 색 (노란 바탕 + 검은 글씨)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFEE500), foregroundColor: const Color(0xD9000000)),
              onPressed: _busy ? null : _kakao,
              icon: const Icon(Icons.chat_bubble),
              label: Text(kakaoReady ? '카카오로 시작하기' : '카카오로 시작하기 (테스트)'),
            ),
            const SizedBox(height: 6),
            Text('카카오 계정의 출생연도·생일·성별로 나이와 성별을 자동 입력해요.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: p.muted)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Row(children: [
                Expanded(child: Divider(color: p.line)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('또는 간편인증', style: TextStyle(fontSize: 12, color: p.muted))),
                Expanded(child: Divider(color: p.line)),
              ]),
            ),
            TextField(controller: _name, maxLength: 20, decoration: const InputDecoration(labelText: '이름', counterText: '')),
            const SizedBox(height: 12),
            TextField(
              controller: _birth,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
              decoration: const InputDecoration(labelText: '생년월일 8자리', hintText: '19950314'),
            ),
            const SizedBox(height: 12),
            Row(children: [gender('M', '남성'), const SizedBox(width: 8), gender('F', '여성')]),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
              decoration: const InputDecoration(labelText: '휴대폰 번호', hintText: '01012345678'),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '인증하는 중…' : '인증하기')),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: p.danger)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 3단계: 가입. 나이·성별은 인증 결과로 자동 입력되고 고칠 수 없다.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  bool _terms = false, _privacy = false, _marketing = false, _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).signup(terms: _terms, privacy: _privacy, marketing: _marketing);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final prof = state.signupProfile;
    final all = _terms && _privacy && _marketing;

    Widget info(String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: p.muted)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
            ]),
          ),
        );

    Widget check(bool value, String label, ValueChanged<bool> onChanged, {bool bold = false}) => CheckboxListTile(
          value: value,
          onChanged: (v) => onChanged(v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label, style: TextStyle(fontSize: 14, color: p.text, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            const _Steps(3),
            const SizedBox(height: 20),
            Text('인증 정보 확인', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: p.text)),
            const SizedBox(height: 8),
            Text('간편인증 결과로 자동 입력됐어요. 고칠 수 없어요.', style: TextStyle(color: p.muted, fontSize: 13)),
            const SizedBox(height: 20),
            if (prof != null)
              Row(children: [
                info('나이', '만 ${prof.age}세 (${prof.birthYear}년생)'),
                const SizedBox(width: 8),
                info('성별', prof.genderLabel),
              ]),
            const SizedBox(height: 20),
            check(all, '전체 동의', (v) => setState(() => _terms = _privacy = _marketing = v), bold: true),
            Divider(color: p.line),
            check(_terms, '(필수) 서비스 이용약관', (v) => setState(() => _terms = v)),
            check(_privacy, '(필수) 개인정보 수집·이용\n대화 내용은 신고 처리를 위해 보관돼요', (v) => setState(() => _privacy = v)),
            check(_marketing, '(선택) 이벤트 알림', (v) => setState(() => _marketing = v)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy || !_terms || !_privacy ? null : _submit, child: Text(_busy ? '가입하는 중…' : '가입하고 시작하기')),
            TextButton(onPressed: _busy ? null : state.backToIdentity, child: const Text('다시 인증하기')),
            if (_error != null) Text(_error!, style: TextStyle(color: p.danger)),
          ],
        ),
      ),
    );
  }
}

/// 블랙리스트에 오른 사람
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = context.pal;
    final info = state.blockedInfo ?? const {};
    final until = (info['until'] as num?)?.toInt();
    final d = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.lock_outline, size: 48, color: p.warn),
              const SizedBox(height: 16),
              Text('이용이 제한된 계정이에요', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: p.text)),
              const SizedBox(height: 12),
              if (info['reason'] != null)
                Text('사유: ${info['reason']}', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
              if (d != null)
                Text('${d.year}년 ${d.month}월 ${d.day}일까지 가입과 로그인이 제한돼요', textAlign: TextAlign.center, style: TextStyle(color: p.muted, height: 1.6)),
              const Spacer(),
              OutlinedButton(onPressed: state.backToIdentity, child: const Text('다른 정보로 인증하기')),
            ],
          ),
        ),
      ),
    );
  }
}
