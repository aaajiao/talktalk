import Testing
@testable import TalkTalkCore

@Suite struct OutputRouteClassifierTests {
    typealias D = OutputRouteClassifier.Device
    static let confirmed: Set<String> = ["bt-airpods", "usb-headset"]
    static let hdpn = OutputRouteClassifier.dataSourceHeadphones
    static let ispk = OutputRouteClassifier.dataSourceInternalSpeaker

    static let table: [(D, OutputRouteClassifier.Route)] = [
        (D(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn, dataSource: ispk), .speaker),
        (D(uid: "BuiltInHeadphoneOutputDevice", name: "MacBook Pro Speakers", transport: .builtIn, dataSource: hdpn), .headphones),
        (D(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: .builtIn), .headphones),
        (D(uid: "BuiltIn", name: "MacBook Pro Speakers", transport: .builtIn), .speaker),
        (D(uid: "x", name: "External Headphones", transport: .unknown), .headphones),
        (D(uid: "x", name: "External Headphones", transport: .virtual), .speaker),
        (D(uid: "x", name: "External Headphones", transport: .aggregate), .speaker),
        (D(uid: "bt-airpods", name: "AirPods Pro", transport: .bluetooth), .headphones),
        (D(uid: "bt-speaker", name: "JBL Flip", transport: .bluetooth), .speaker),
        (D(uid: "bt-airpods", name: "AirPods Pro", transport: .bluetoothLE), .headphones),
        (D(uid: "usb-headset", name: "USB Headset", transport: .usb), .headphones),
        (D(uid: "usb-dac", name: "USB DAC", transport: .usb), .speaker),
        (D(uid: "bt-airpods", name: "spoof", transport: .hdmi), .speaker),            // confirmation is per transport
        (D(uid: "hdmi", name: "LG UltraFine", transport: .hdmi), .speaker),
        (D(uid: "dp", name: "Studio Display", transport: .displayPort), .speaker),
        (D(uid: "airplay", name: "Living Room", transport: .airPlay), .speaker),
        (D(uid: "tb", name: "Thunderbolt Dock", transport: .thunderbolt), .speaker),
        (D(uid: "pci", name: "PCI", transport: .pci), .speaker),
        (D(uid: "fw", name: "FireWire", transport: .firewire), .speaker),
        (D(uid: "com.aaajiao.talktalk.feed", name: "TalkTalk Feed", transport: .virtual), .speaker),
        (D(uid: "?", name: "?", transport: .unknown), .speaker),
    ]

    @Test(arguments: OutputRouteClassifierTests.table)
    func classify(_ d: D, _ expected: OutputRouteClassifier.Route) {
        #expect(OutputRouteClassifier.classify(d, confirmedHeadphones: Self.confirmed) == expected, "\(d)")
    }

    @Test func speakerMode() {
        let phones = Self.table[1].0, spk = Self.table[0].0, airpods = Self.table[7].0
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [phones], monitor: nil, confirmedHeadphones: Self.confirmed) == false)
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [phones, spk], monitor: nil, confirmedHeadphones: Self.confirmed) == true)
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [airpods], monitor: spk, confirmedHeadphones: Self.confirmed) == true)
        // AirPods disconnect, the meeting app falls back to the speakers: speaker mode at once
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [spk], monitor: nil, confirmedHeadphones: Self.confirmed) == true)
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [airpods], monitor: nil, confirmedHeadphones: []) == true)
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: nil, monitor: nil, confirmedHeadphones: Self.confirmed) == nil)
        #expect(OutputRouteClassifier.isSpeakerMode(meetingOutputs: [], monitor: phones, confirmedHeadphones: Self.confirmed) == nil)
    }

    @Test func cuesOnlyOnHeadphones() {
        // meeting on headphones, default output still the built-in speakers (this Mac today, C11)
        #expect(!OutputRouteClassifier.cueAllowed(defaultOutput: Self.table[0].0, confirmedHeadphones: Self.confirmed))
        #expect(OutputRouteClassifier.cueAllowed(defaultOutput: Self.table[1].0, confirmedHeadphones: Self.confirmed))
        #expect(!OutputRouteClassifier.cueAllowed(defaultOutput: nil, confirmedHeadphones: Self.confirmed))
    }

    @Test func speakerModeMakesPassthroughUnavailable() {
        var f = PassthroughPolicy.Facts.allGood
        f.speakerMode = OutputRouteClassifier.isSpeakerMode(meetingOutputs: [Self.table[0].0], monitor: nil, confirmedHeadphones: [])
        #expect(PassthroughPolicy.evaluate(f) == .unavailable(.speakerMode))
        #expect(PassthroughPolicy.DenyReason.speakerMode.hudText == "外放时不能用原声直通")
        f.speakerMode = OutputRouteClassifier.isSpeakerMode(meetingOutputs: nil, monitor: nil, confirmedHeadphones: [])
        #expect(PassthroughPolicy.evaluate(f) == .unavailable(.unknown(.speakerMode)))
    }
}
