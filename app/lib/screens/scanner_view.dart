import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// 카메라 미리보기 + 가운데 네모 가이드 + 손전등. QR 값을 한 번 읽으면 onCode 를 부른다.
class ScannerView extends StatefulWidget {
  const ScannerView({super.key, required this.onCode});
  final Future<void> Function(String code) onCode;

  @override
  State<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<ScannerView> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _busy = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue;
    if (value == null) return;
    setState(() => _busy = true);
    try {
      await widget.onCode(value);
    } finally {
      // 같은 QR을 연속으로 읽지 않도록 잠깐 쉰다
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: p.accent, width: 4),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Text(
            _busy ? '연결하는 중…' : 'QR을 네모 안에 맞춰주세요',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15, shadows: [Shadow(blurRadius: 6)]),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: IconButton.filled(
            tooltip: '손전등',
            style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
            onPressed: () async {
              await _controller.toggleTorch();
              setState(() => _torch = !_torch);
            },
            icon: Icon(_torch ? Icons.flashlight_off : Icons.flashlight_on),
          ),
        ),
      ],
    );
  }
}
