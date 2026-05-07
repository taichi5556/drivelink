import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// QR コード読み取り画面。検出した文字列を `Navigator.pop` で返却。
/// 検出時は自動で閉じる（呼出側でルームコード抽出 + 入力欄反映）。
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _detected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    _detected = true;
    Navigator.pop(context, raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('QRコードを読み取る', style: TextStyle(fontSize: 16)),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // 中央 QR ガイド枠 + 暗転 overlay
          _ScannerOverlay(),
          // 下部説明文
          const Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'QRコードを枠内に収めてください',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 中央の正方形を切り抜いて暗くする overlay + 白い角枠
class _ScannerOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide * 0.7;
        return Stack(
          alignment: Alignment.center,
          children: [
            // 半透明 overlay（中央は ColorFiltered で抜くと複雑なので簡易表現）
            Container(color: Colors.black.withValues(alpha: 0.4)),
            // 中央の透明な四角（枠線のみ）
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00D4FF), width: 3),
              ),
            ),
          ],
        );
      },
    );
  }
}
