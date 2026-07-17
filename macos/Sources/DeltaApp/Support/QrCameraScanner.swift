import AVFoundation
import CoreImage
import SwiftUI

/// Live QR scanning from the Mac's camera for the "Add Second Device" flow:
/// hold the phone showing the DCBACKUP QR up to the FaceTime camera.
///
/// Frames arrive on a private serial queue; detection runs there with a
/// queue-confined CIDetector, throttled. The first hit fires `onFound`
/// exactly once.
final class QrCameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "qr-camera-scan")
    private let onFound: @Sendable (String) -> Void
    // Detector + lastScan are queue-confined; `finished` is lock-guarded so
    // stop() takes effect IMMEDIATELY — an async flag set via the queue would
    // let frames already enqueued ahead of it fire onFound after stop().
    private let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    private var lastScan = Date.distantPast
    private let stateLock = NSLock()
    private var finished = false

    init?(onFound: @escaping @Sendable (String) -> Void) {
        self.onFound = onFound
        super.init()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }

        session.beginConfiguration()
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// startRunning/stopRunning block; keep them off the main thread.
    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() {
        stateLock.lock()
        finished = true
        stateLock.unlock()
        queue.async { self.session.stopRunning() }
    }

    /// Atomically checks-and-sets `finished`; returns whether we won.
    private func tryFinish() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isFinished,
              Date().timeIntervalSince(lastScan) > 0.15,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastScan = Date()

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let payload = detector?
            .features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
        if let payload, tryFinish() {
            session.stopRunning()
            onFound(payload)
        }
    }
}

/// AppKit-backed live camera preview.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
