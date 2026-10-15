import CoreImage
import Testing
@testable import V2MacCore

@Suite struct QRCodeReaderTests {
    func qr(_ text: String) throws -> CGImage {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return try #require(CIContext().createCGImage(image, from: image.extent))
    }

    @Test func readsTheLinkInACode() throws {
        let link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@node.example.com:443?type=ws&security=tls#🇩🇪 Demo"
        #expect(QRCodeReader.messages(in: try qr(link)) == [link])
    }

    @Test func aPictureWithoutACodeGivesNothing() throws {
        let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try #require(CIContext().createCGImage(blank, from: blank.extent))
        #expect(QRCodeReader.messages(in: image).isEmpty)
    }
}
