import Testing

@testable import DeltaApp

/// QR image rendering for invite links (issue: qr-invite-contact-flow).
@Suite struct QrRenderTests {
    @MainActor @Test func rendersSquareImageForInviteLink() throws {
        let image = try #require(qrImage(for: "https://i.delta.chat/#TESTFPR&a=x%40y.org&n=X"))
        #expect(image.size.width > 0)
        #expect(image.size.width == image.size.height)
    }

    @MainActor @Test func emptyPayloadRendersNothing() {
        #expect(qrImage(for: "") == nil)
    }
}
