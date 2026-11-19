import 'package:flutter/material.dart';

import '../main.dart';
import '../state.dart';
import '../theme.dart';
import 'scanner_view.dart';

/// 처음 실행: 테스트 서버 주소를 입력하거나, PC 화면의 QR을 찍어서 바로 시작한다.
/// (정식 버전에서는 이 자리에 실명인증이 들어간다)
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _url = TextEditingController(text: 'http://192.168.0.');
  bool _busy = false;
  String? _error;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).setServer(_url.text);
    } catch (e) {
      setState(() => _error = e is ApiError ? e.message : '서버에 연결하지 못했어요. 주소와 와이파이를 확인해 주세요');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanToStart() async {
    final state = AppScope.read(context);
    final roomId = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (c) => Scaffold(
        appBar: AppBar(title: const Text('PC 화면의 QR 찍기')),
        body: ScannerView(onCode: (code) async {
          try {
            final room = await state.joinFromCode(code);
            if (c.mounted) Navigator.of(c).pop(room.id);
          } on ApiError catch (e) {
            // 서버 주소는 QR에서 읽었고, 인증을 마치면 이 QR로 바로 들어간다
            if (e.code == 'later') {
              if (c.mounted) Navigator.of(c).pop();
            } else {
              toast(e.message);
            }
          } catch (e) {
            toast(e.toString());
          }
        }),
      ),
    ));
    if (roomId != null) openChat(roomId);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Text('5분 채팅', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: p.text)),
            const SizedBox(height: 8),
            Text('서버 주소를 정해 주세요. 정식 배포 버전에는 서버 주소가 미리 들어가 있어서 이 화면이 나오지 않아요.', style: TextStyle(color: p.muted, height: 1.5)),
            const SizedBox(height: 40),
            FilledButton.icon(
              onPressed: _busy ? null : _scanToStart,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('PC 화면의 QR 찍고 바로 시작'),
            ),
            const SizedBox(height: 8),
            Text('PC에서 서버를 켜고 테스트 웹페이지를 열면 QR이 보여요.', style: TextStyle(color: p.muted, fontSize: 13)),
            const SizedBox(height: 36),
            Text('또는 서버 주소 직접 입력', style: TextStyle(fontWeight: FontWeight.w600, color: p.text)),
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'http://192.168.0.10:3000'),
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : _connect, child: Text(_busy ? '연결 중…' : '연결')),
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
