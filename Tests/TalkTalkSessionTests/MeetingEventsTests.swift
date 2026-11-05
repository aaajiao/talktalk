import Testing
@testable import TalkTalkCore
@testable import TalkTalkSession

@MainActor
@Suite struct MeetingEventsTests {
    @Test func everySubscriberGetsEveryEventInOrder() {
        let hub = MeetingEvents()
        var a: [MeetingEvent] = [], b: [MeetingEvent] = []
        let sa = hub.subscribe { a.append($0) }
        let sb = hub.subscribe { b.append($0) }
        let seq: [MeetingEvent] = [.started(appID: "us.zoom.xos", appName: "Zoom", lang: .en), .suspended(.sleep),
                                   .resumed(afterSleep: true), .audioServiceRestarted(at: 1), .ended(.user)]
        seq.forEach(hub.emit)
        #expect(a == seq && b == seq)
        _ = (sa, sb)
    }

    @Test func cancelAndReleaseBothUnsubscribe() {
        let hub = MeetingEvents()
        var n = 0
        let kept = hub.subscribe { _ in n += 1 }
        do { _ = hub.subscribe { _ in n += 100 } }   // released at once
        #expect(hub.subscriberCount == 1)
        hub.emit(.resumed(afterSleep: false))
        kept.cancel()
        hub.emit(.resumed(afterSleep: false))
        #expect(n == 1 && hub.subscriberCount == 0)
    }

    @Test func aHandlerMayCancelItselfWhileCalled() {
        let hub = MeetingEvents()
        var sub: MeetingSubscription?
        var calls = 0
        sub = hub.subscribe { _ in calls += 1; sub?.cancel() }
        hub.emit(.resumed(afterSleep: false))
        hub.emit(.resumed(afterSleep: false))
        #expect(calls == 1)
    }

    @Test func stateAndHintAreNotLifecycle() {
        #expect(!MeetingEvent.state(.idle).isLifecycle)
        #expect(!MeetingEvent.hint(nil).isLifecycle)
        #expect(MeetingEvent.ended(.afterSleep).isLifecycle)
    }
}
