import Testing
@testable import TalkTalkCore

struct SpeakRepeatCheckTests {
    /// Invented sentences. A short clip is dropped only when it re-says the previous source's
    /// ending from an exact first unit, give or take a modal/filler particle. Any other added,
    /// dropped or changed unit (a date, unit, quantity, negation or Latin word), and repeats of the
    /// beginning or middle, are kept.
    @Test func dropsOnlyShortRepeatsOfThePreviousEnding() throws {
        let check = SpeakRepeatCheck(try TestResources.profile().speak)
        let p1 = "我们下周三把样品寄给客户。", p2 = "我们明天再讨论这个吧。", p3 = "这个版本改用Swift重写设置界面。"
        let p4 = "We can ship the beta on Friday.", p5 = "预算定在三千五百元。", p6 = "我们不寄给客户。"
        let pn = "这是张伟的方案。"
        typealias Verdict = SpeakRepeatCheck.Verdict
        let rows: [(String, String?, Bool, Bool, Verdict, Int?)] = [
            ("样品寄给客户", p1, true, false, .repeated, 100),
            ("样品寄给客户了", p1, true, false, .repeated, 86),
            ("明天再讨论这个", p2, true, false, .repeated, 100),
            ("Swift重写设置界面", p3, true, false, .repeated, 100),
            ("ＳＷＩＦＴ重写设置界面", p3, true, false, .repeated, 100),
            ("the beta on Friday", p4, true, false, .repeated, 100),
            ("吧样品寄给客户", p1, true, false, .protectedEdit, 86),
            ("李伟的方案", pn, true, false, .protectedEdit, 80),
            ("不寄给客户", p1, true, false, .protectedEdit, 80),
            ("六千五百元", p5, true, false, .protectedEdit, 80),
            ("Kotlin重写设置界面", p3, true, false, .protectedEdit, 86),
            ("我们寄给客户", p6, true, false, .protectedEdit, 100),
            ("改到下周五", "我们把会议改到周五。", true, false, .protectedEdit, 80),
            ("定在三千美元", "预算定在三千元。", true, false, .protectedEdit, 83),
            ("这批货五十公斤", "这批货五十斤。", true, false, .protectedEdit, 86),
            ("明天得去开会", "我们明天去开会。", true, false, .protectedEdit, 83),
            ("明天下午到公司签合同", "客户明天上午到公司签合同。", true, false, .protectedEdit, 90),
            ("毛利率是-5%", "这季度毛利率是5%。", true, false, .protectedEdit, 86),
            ("增长了5%", "今年利润增长了5。", true, false, .protectedEdit, 80),
            ("预算定在€5000", "我们把预算定在$5000。", true, false, .different, 83),
            ("预算定在$5000", "我们把预算定在$5000。", true, false, .repeated, 100),
            ("３５％的客户", "大约有35%的客户。", true, false, .repeated, 100),
            ("完成了A+轮融资", "我们完成了A轮融资。", true, false, .protectedEdit, 88),
            ("来10+个人", "这次来10个人。", true, false, .protectedEdit, 80),
            ("温度是–5度", "温度是5度。", true, false, .protectedEdit, 83),
            ("温度>30度报警", "温度<30度报警。", true, false, .different, 86),
            ("改用C++重写", "这个模块改用C++重写。", true, false, .repeated, 100),
            ("我们下周三", p1, true, false, .notAtEnd, 100),
            ("ship the beta on Monday", p4, true, false, .notAtEnd, 80),
            ("寄给客户然后开会", p1, true, false, .different, 50),
            ("明天下午开会", "我们明天上午开会。", true, false, .different, 83),
            ("样品寄给客户", "样品今天寄给客户。", true, false, .different, 100),
            ("on Friday", p4, true, false, .fewTokens, 100),
            ("样品寄给客户", nil, true, false, .noPrevious, nil),
            ("样品寄给客户", p1, false, false, .longSpeech, 100),
            ("样品寄给客户", p1, true, true, .shortReply, 100),
        ]
        for (text, previous, short, shortReply, verdict, pct) in rows {
            let result = check.evaluate(text, previous: previous, short: short, shortReply: shortReply)
            #expect(result.verdict == verdict && result.similarityPct == pct, "\(text)")
        }
        // Re-saying the ending of a sentence already known to be unsent is not a repeat.
        let unsent = check.evaluate("样品寄给客户", previous: p1, previousUndelivered: true, short: true, shortReply: false)
        #expect(unsent == .init(verdict: .previousNotSent, tokens: 6, similarityPct: 100))
    }
}
