import Testing
@testable import TalkTalkCore

private typealias D = MicPolicy.Device

private let builtIn = D(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: "bltn")
private let usb = D(uid: "AppleUSBAudioEngine:Shure:MV7:1", name: "Shure MV7", transport: "usb ")
private let thunder = D(uid: "TB:Apollo", name: "Apollo Twin", transport: "thun")
private let pci = D(uid: "PCI:Card", name: "PCI Card", transport: "pci ")
private let ear4 = D(uid: "00-11-22:input", name: "ear (4)", transport: "blue")
private let bleMic = D(uid: "ble:input", name: "LE Headset", transport: "blea")
private let iphone = D(uid: "ccwl:iphone", name: "iPhone Microphone", transport: "ccwl")
private let ttMic = D(uid: "com.aaajiao.talktalk.mic", name: "TalkTalk Mic", transport: "virt")
private let ttTestMic = D(uid: "com.aaajiao.talktalk.testmic", name: "TalkTalk Test Mic", transport: "virt")
private let ttTap = D(uid: "com.aaajiao.talktalk.tap.42", name: "tap", transport: "grup", isAggregate: true)
private let tuwaVirt = D(uid: "TuwaMic_UID", name: "Tuwa Mic", transport: "virt")
private let tuwaOdd = D(uid: "TuwaMic_UID2", name: "Tuwa Microphone", transport: "bltn")  // lies about transport
private let teams = D(uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio", transport: "usb ")
private let aggregate = D(uid: "agg:1", name: "My Aggregate", transport: "grup", isAggregate: true)
private let autoAgg = D(uid: "agg:2", name: "Auto Aggregate", transport: "fgrp")
private let aggByClass = D(uid: "agg:3", name: "Class Aggregate", transport: "bltn", isAggregate: true)
private let deadUSB = D(uid: "usb:dead", name: "Dead USB", transport: "usb ", isAlive: false)

@Suite struct MicPolicyRule2Tests {
    struct Row: Sendable, CustomTestStringConvertible {
        let device: MicPolicy.Device
        let exclusion: MicPolicy.Exclusion?
        var testDescription: String { device.name }
    }

    static let rows: [Row] = [
        Row(device: builtIn, exclusion: nil),
        Row(device: usb, exclusion: nil),
        Row(device: thunder, exclusion: nil),
        Row(device: pci, exclusion: nil),
        Row(device: ear4, exclusion: nil),          // Bluetooth passes rule 2 (rule 5 is separate)
        Row(device: bleMic, exclusion: nil),
        Row(device: iphone, exclusion: nil),
        Row(device: deadUSB, exclusion: nil),       // liveness is not rule 2
        Row(device: ttMic, exclusion: .ownDevice),
        Row(device: ttTestMic, exclusion: .ownDevice),
        Row(device: ttTap, exclusion: .ownDevice),
        Row(device: tuwaVirt, exclusion: .virtual),
        Row(device: tuwaOdd, exclusion: .excludedByName),
        Row(device: teams, exclusion: .excludedByName),
        Row(device: aggregate, exclusion: .aggregate),
        Row(device: autoAgg, exclusion: .aggregate),
        Row(device: aggByClass, exclusion: .aggregate),
        Row(device: D(uid: "x", name: "BlackHole 2ch", transport: "virt"), exclusion: .virtual),
        Row(device: D(uid: "com.aaajiao.talktalk", name: "bare id", transport: "usb "), exclusion: .ownDevice),
    ]

    @Test(arguments: rows) func rule2(_ row: Row) {
        #expect(MicPolicy.exclusion(row.device) == row.exclusion)
        #expect(MicPolicy.passesRule2(row.device) == (row.exclusion == nil))
    }

    @Test func usableNeedsAlive() {
        #expect(MicPolicy.isUsable(usb))
        #expect(!MicPolicy.isUsable(deadUSB))
        #expect(!MicPolicy.isUsable(ttMic))
    }

    @Test func otherVendorsWithOurWordAreNotOwn() {
        #expect(!MicPolicy.isOwnUID("com.aaajiao.talktalkfoo"))
        #expect(MicPolicy.isOwnUID("com.aaajiao.talktalk.feed"))
    }
}

@Suite struct MicPolicySelectionTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let devices: [MicPolicy.Device]
        let userUID: String?
        let expectUID: String?
        let source: MicPolicy.Selection.Source?
        let problem: MicPolicy.UserPickProblem?
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "built-in by default", devices: [usb, builtIn, ear4], userUID: nil,
            expectUID: builtIn.uid, source: .builtIn, problem: nil),
        Row(name: "no built-in → first USB/TB/PCI", devices: [ear4, thunder, usb], userUID: nil,
            expectUID: thunder.uid, source: .otherCandidate, problem: nil),
        Row(name: "never auto-pick Bluetooth", devices: [ear4, bleMic, ttMic], userUID: nil,
            expectUID: nil, source: nil, problem: nil),
        Row(name: "never auto-pick Continuity", devices: [iphone], userUID: nil,
            expectUID: nil, source: nil, problem: nil),
        Row(name: "never pick virtual/own/aggregate", devices: [ttMic, tuwaVirt, teams, aggregate], userUID: nil,
            expectUID: nil, source: nil, problem: nil),
        Row(name: "dead candidates skipped", devices: [deadUSB, pci], userUID: nil,
            expectUID: pci.uid, source: .otherCandidate, problem: nil),
        Row(name: "user pick wins", devices: [builtIn, usb], userUID: usb.uid,
            expectUID: usb.uid, source: .user, problem: nil),
        Row(name: "user may pick Bluetooth (after confirmation)", devices: [builtIn, ear4], userUID: ear4.uid,
            expectUID: ear4.uid, source: .user, problem: nil),
        Row(name: "user may pick Continuity", devices: [builtIn, iphone], userUID: iphone.uid,
            expectUID: iphone.uid, source: .user, problem: nil),
        Row(name: "user pick must pass rule 2: TalkTalk Mic", devices: [builtIn, ttMic], userUID: ttMic.uid,
            expectUID: builtIn.uid, source: .builtIn, problem: .excluded(.ownDevice)),
        Row(name: "user pick must pass rule 2: Tuwa", devices: [builtIn, tuwaOdd], userUID: tuwaOdd.uid,
            expectUID: builtIn.uid, source: .builtIn, problem: .excluded(.excludedByName)),
        Row(name: "user pick must pass rule 2: aggregate", devices: [usb, aggregate], userUID: aggregate.uid,
            expectUID: usb.uid, source: .otherCandidate, problem: .excluded(.aggregate)),
        Row(name: "user pick missing", devices: [builtIn], userUID: "gone",
            expectUID: builtIn.uid, source: .builtIn, problem: .missing),
        Row(name: "user pick dead", devices: [builtIn, deadUSB], userUID: deadUSB.uid,
            expectUID: builtIn.uid, source: .builtIn, problem: .notAlive),
        Row(name: "nothing at all", devices: [], userUID: nil, expectUID: nil, source: nil, problem: nil),
    ]

    @Test(arguments: rows) func select(_ row: Row) {
        let s = MicPolicy.select(row.devices, userUID: row.userUID)
        #expect(s.device?.uid == row.expectUID)
        #expect(s.source == row.source)
        #expect(s.userPickProblem == row.problem)
    }

    @Test func pickNotices() {
        #expect(MicPolicy.pickNotice(ear4) == .confirmBluetoothHFP)
        #expect(MicPolicy.pickNotice(bleMic) == .confirmBluetoothHFP)
        #expect(MicPolicy.pickNotice(ear4)?.needsConfirmation == true)
        #expect(MicPolicy.pickNotice(ear4)?.text == "耳机会切到通话音质，识别也会变差")
        #expect(MicPolicy.pickNotice(iphone) == .continuityLatency)
        #expect(MicPolicy.pickNotice(iphone)?.needsConfirmation == false)
        #expect(MicPolicy.pickNotice(iphone)?.text.contains("125 ms") == true)
        #expect(MicPolicy.pickNotice(builtIn) == nil)
        #expect(MicPolicy.pickNotice(usb) == nil)
    }

    @Test func pickableListsPhysicalOnly() {
        let all = [builtIn, usb, ear4, iphone, ttMic, tuwaVirt, teams, aggregate, deadUSB]
        #expect(MicPolicy.pickable(all).map(\.uid) == [builtIn.uid, usb.uid, ear4.uid, iphone.uid])
    }

    @Test func micConstant() {
        #expect(MicPolicy.talkTalkMicUID == "com.aaajiao.talktalk.mic")
        #expect(MicPolicy.isTalkTalkMic(ttMic))
        #expect(!MicPolicy.isTalkTalkMic(ttTestMic))
        #expect(!MicPolicy.isTalkTalkMic(nil))
    }
}
