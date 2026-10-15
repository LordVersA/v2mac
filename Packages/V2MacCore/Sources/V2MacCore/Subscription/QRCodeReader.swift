import CoreImage

/// Reads share links and subscription URLs from QR codes in a picture (a screenshot, a saved
/// image), so they can be added like pasted text.
public enum QRCodeReader {
    /// The text of every QR code in `image`.
    public static func messages(in image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
