import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/api/pairing.dart';

/// Scans a server QR code.
///
/// Understands both the official OpenCode pairing payload
/// (`{"code":...,"urls":[...]}` or a `/auth/connect/<code>` link, as shown by
/// the desktop app and `opencode pair`) and the `tool/qr_serve` payload.
///
/// The preview is laid out with [StackFit.expand] so it receives the full body
/// size as a *tight* constraint. With loose constraints the platform view can
/// end up sized to the camera resolution instead of the screen, leaving part of
/// the viewport showing the scaffold background.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
  );

  double _zoom = 0;
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    _handled = true;
    _handleCapture(capture);
  }

  void _handleCapture(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final payload = parsePairingPayload(raw);
      if (payload == null) continue;
      Navigator.of(context).pop(payload);
      return;
    }
    _handled = false;
    _notify('No pairing code found in that image. Try again or type the server '
        'address manually.');
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fallback for when the camera cannot resolve the code - a dense pairing
  /// payload is a ~50x50 module QR, which needs the phone to be close and
  /// steady. Picking an image of the code (a screenshot, for instance) avoids
  /// focus and distance entirely.
  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final capture = await _controller.analyzeImage(picked.path);
      if (capture == null || capture.barcodes.isEmpty) {
        _notify('No QR code found in that image.');
        return;
      }
      _handled = true;
      _handleCapture(capture);
    } catch (e) {
      _notify('Could not read that image: $e');
    }
  }

  Future<void> _onZoomChanged(double value) async {
    setState(() => _zoom = value);
    try {
      await _controller.setZoomScale(value);
    } catch (_) {
      // Zoom is unavailable on some devices; the slider becomes a no-op.
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Torch is not available on this device')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan server QR'),
        actions: [
          IconButton(
            tooltip: 'Pick image',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _pickImage,
          ),
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flashlight_on),
            onPressed: _toggleTorch,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            fit: BoxFit.cover,
            tapToFocus: true,
            placeholderBuilder: (_) => const ColoredBox(color: Colors.black),
            overlayBuilder: (context, constraints) =>
                _ScanOverlay(size: constraints.biggest),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ZoomSlider(value: _zoom, onChanged: _onZoomChanged),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Point at the pairing code. Zoom in if it is small.',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dimmed mask with a bright window where the code should be aimed.
///
/// Pairing codes are dense (a 100-character JSON payload at error-correction
/// level M is roughly 50x50 modules), so an explicit target plus zoom makes the
/// whole code land in focus.
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay({required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    final window = (size.height * 0.5).clamp(220.0, 420.0);
    return IgnorePointer(
      child: Stack(
        children: [
          // Dim everything outside the target window.
          ColorFiltered(
            colorFilter: ColorFilter.mode(
              Colors.black.withValues(alpha: 0.55),
              BlendMode.srcOver,
            ),
            child: Container(color: Colors.transparent),
          ),
          Center(
            child: Container(
              width: window,
              height: window,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(16),
                color: Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomSlider extends StatelessWidget {
  const _ZoomSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.zoom_out, size: 18, color: scheme.onPrimary),
          Expanded(
            child: Slider(
              value: value,
              onChanged: onChanged,
            ),
          ),
          Icon(Icons.zoom_in, size: 18, color: scheme.onPrimary),
        ],
      ),
    );
  }
}