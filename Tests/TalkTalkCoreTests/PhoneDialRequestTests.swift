import Testing
@testable import TalkTalkCore

@Suite struct PhoneDialRequestTests {
    @Test func acceptsDomesticAndInternationalFormattingAsOneDestination() {
        #expect(PhoneDialRequest.url(for: "+49 (30) 1234-5678")?.absoluteString == "tel:+493012345678")
        #expect(PhoneDialRequest.url(for: " 030 123 4567 ")?.absoluteString == "tel:0301234567")
        #expect(PhoneDialRequest.url(for: "+49\u{00a0}30\u{2011}1234567")?.absoluteString == "tel:+49301234567")
        #expect(PhoneDialRequest.url(for: "123")?.absoluteString == "tel:123")
        #expect(PhoneDialRequest.url(for: "+123456789012345")?.absoluteString == "tel:+123456789012345")
    }

    @Test(arguments: ["", "  () - ", "+", "12", "+12", "1234567890123456", "+1234567890123456",
                      "++4930123", "4930+123", "４９３０１２３", "٤٩٣٠١٢٣"])
    func rejectsMalformedNumbers(_ raw: String) {
        #expect(PhoneDialRequest.url(for: raw) == nil)
    }

    @Test(arguments: ["tel:+49301234567", "https://example.com/123", "123?x=456", "123%23456",
                      "123&456", "123/456", "123\\456", "*123#", "123,456", "123;456", "123#456",
                      "123 ext 456", "123p456", "123w456", "123@456"])
    func rejectsSchemesServicesExtensionsAndURLSyntax(_ raw: String) {
        #expect(PhoneDialRequest.url(for: raw) == nil)
    }

    @Test(arguments: ["123\n456", "123\r456", "123\r\n456", "123\t456", "123\u{0000}456",
                      "123\u{2028}456", "123\u{2029}456", "123\u{200b}456", "123\u{202e}456"])
    func rejectsMultipleLinesAndInvisibleControls(_ raw: String) {
        #expect(PhoneDialRequest.url(for: raw) == nil)
    }
}
