import XCTest

final class LandscapeNavigationTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    /// Home group rows, whatever lighting zones the household lists. A row that
    /// is not mounted must never be queried: XCUI throws for a missing element.
    private let homeRows = ["child-everything", "child-conservatory", "child-kitchen", "child-lounge"]
    /// Focusables this suite drives, used to report where focus actually went.
    private let knownTargets = ["__orb-dial", "__quick-lights", "__quick-aircon-dial",
                                "__quick-heater-dial", "__quick-on", "__quick-off",
                                "section-__phonoscope",
                                "child-everything", "child-conservatory", "child-kitchen",
                                "child-lounge", "everything-brightness", "everything-on",
                                "section-climate", "section-outside", "section-network",
                                "section-__timers"]

    override func setUp() {
        continueAfterFailure = false
        // NOVA_UITEST slows the band's ticks: XCUI waits for the app to go quiet
        // between interactions, and this dashboard never does. See UITestHarness.
        app.launchEnvironment["NOVA_UITEST"] = "1"
        app.launch()
        XCTAssertTrue(element("__orb-dial").waitForExistence(timeout: 60),
                      "The orb must appear once state arrives")
    }

    // MARK: - The dashboard's own state

    /// The dashboard publishes focus, edit state and move accounting under
    /// NOVA_UITEST; see `LandscapeDashboard.focusStateProbe`. XCUI can only say
    /// which element has focus, which is not enough to tell a press the
    /// simulator never delivered from one the dashboard dropped.
    /// Verdict on where the dashboard's focus is, using the state the app
    /// publishes about itself. The simulator's accessibility focus attribute
    /// lags a programmatic focus set and sometimes reports no focused element
    /// at all, so the OS view is printed for diagnosis and the app's own state
    /// is what the suite asserts.
    private func expectStateFocus(_ id: String, _ point: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let token = Self.focusToken(forAccessibilityID: id)
        let before = field("beat")
        var raw = rawState()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !raw.contains("focus=\(token)"), field("beat") == before {
            Thread.sleep(forTimeInterval: 0.3)
            raw = rawState()
        }
        print("NOVA-FOCUS \(point.isEmpty ? id : point): app=\(field("focus")) os=\(focusedIDs())")
        XCTAssertEqual(field("focus"), token, "\(point.isEmpty ? id : point): the dashboard is not on \(token)",
                       file: file, line: line)
    }

    /// The accessibility identifier of the control a focus token names.
    private static func accessibilityID(forFocusToken token: String) -> String {
        if token.hasPrefix("section:") { return "section-" + token.dropFirst("section:".count) }
        if token.hasPrefix("child:") { return "child-" + token.dropFirst("child:".count) }
        if token.hasPrefix("brightness:") { return token.dropFirst("brightness:".count) + "-brightness" }
        if token == "action:__orb/dial" { return "__orb-dial" }
        if token.hasPrefix("action:__quick/") { return "__quick-" + token.dropFirst("action:__quick/".count) }
        return token
    }

    private static func focusToken(forAccessibilityID id: String) -> String {
        if id.hasPrefix("section-") { return "section:" + id.dropFirst("section-".count) }
        if id.hasPrefix("child-") { return "child:" + id.dropFirst("child-".count) }
        if id.hasSuffix("-brightness") { return "brightness:" + id.dropLast("-brightness".count) }
        if id == "__orb-dial" { return "action:__orb/dial" }
        if id.hasPrefix("__quick-") { return "action:__quick/" + id.dropFirst("__quick-".count) }
        return id
    }

    private func rawState() -> String {
        let probe = element("__nova-focus-state")
        return probe.exists ? (probe.value as? String ?? "<no value>") : "<probe missing>"
    }
    private func field(_ name: String) -> String {
        for pair in rawState().split(separator: " ") where pair.contains("=") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == name { return String(parts[1]) }
        }
        return ""
    }
    /// Presses the app saw, and presses the magnetic gate let through.
    private func moves() -> (received: Int, accepted: Int) {
        let parts = field("moves").split(separator: "/")
        guard parts.count == 2, let received = Int(parts[0]), let accepted = Int(parts[1]) else {
            return (0, 0)
        }
        return (received, accepted)
    }
    @discardableResult
    private func state(_ point: String) -> String {
        let raw = rawState()
        print("NOVA-STATE \(point): \(raw)")
        return raw
    }
    /// At launch the focus engine has not engaged yet and the OS reports no
    /// focused element at all, so the dashboard's own state is the only honest
    /// answer to "where does the first press start from".
    private func expectState(_ needle: String, _ point: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let raw = state(point)
        XCTAssertTrue(raw.contains(needle), "\(point): expected \(needle), got \(raw)",
                      file: file, line: line)
    }

    // MARK: - Focus as the OS sees it

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func matches(_ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }
    /// A control can carry its identifier on more than one nested element, so
    /// look at every match rather than trusting `firstMatch`.
    private func focused(_ id: String) -> Bool {
        matches(id).allElementsBoundByIndex.contains { $0.hasFocus }
    }
    private func focusedIDs() -> [String] {
        (knownTargets + homeRows).filter(focused)
    }
    /// Where the OS says focus is, plus the dashboard's own view of it. Kept
    /// cheap on purpose: resolving every element in this app takes minutes, and
    /// minutes of no input is long enough for the encoder's idle commit to close
    /// the edit the next press was meant to adjust.
    private func report(_ point: String) {
        print("NOVA-UI \(point): " + focusedIDs().joined(separator: ","))
        state(point)
    }
    /// Who holds focus anywhere in the app, by accessibility identifier. Slow
    /// (every element is resolved), so it is only worth asking on failure.
    private func focusedAnywhere() -> String {
        let focused = app.descendants(matching: .any).allElementsBoundByIndex
            .filter { $0.hasFocus }
            .map { "\($0.elementType.rawValue):'\($0.identifier)'" }
        let present = ["child-everything", "child-conservatory", "child-bedroom"]
            .map { "\($0)=\(matches($0).count)" }
        return "focusedAnywhere=\(focused.isEmpty ? "nothing" : focused.joined(separator: ","))" +
               " present=\(present.joined(separator: " "))"
    }
    /// The app never goes idle (the orb, the fluid background and the dial ticks
    /// all animate), so XCUI needs a long deadline; poll the attribute directly
    /// rather than leaning on the predicate-expectation machinery.
    
    // MARK: - Input

    private func send(_ button: XCUIRemote.Button) {
        remote.press(button)
        // Longer than focus settling and than the magnetic gate's repeat
        // window, shorter than the encoder's idle commit.
        Thread.sleep(forTimeInterval: 0.6)
    }
    /// Sends one press and waits for the dashboard to show it landed. The
    /// simulator's remote path is not synchronous and this dashboard never goes
    /// idle, so a press can be swallowed or arrive late; a press the dashboard
    /// never showed is sent again, one it did show never is, so "one press, one
    /// item" still means exactly one item of travel.
    private func press(_ button: XCUIRemote.Button, expecting needle: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 1...3 {
            send(button)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if rawState().contains(needle) {
                    print("NOVA-PRESS \(button.rawValue) attempt \(attempt) landed \(needle)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            print("NOVA-PRESS \(button.rawValue) attempt \(attempt) did not land: \(rawState())")
        }
        XCTFail("\(button.rawValue) never produced \(needle); dashboard state is \(rawState())",
                file: file, line: line)
    }
    /// A press whose only visible effect is inside the control that holds the
    /// edit — stepping an encoder's channel. The dashboard's own move counter
    /// says whether the press arrived without pinning the channel it stepped to.
    private func pressCounting(_ button: XCUIRemote.Button,
                               file: StaticString = #filePath, line: UInt = #line) {
        let before = moves().accepted
        for attempt in 1...3 {
            send(button)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if moves().accepted > before {
                    print("NOVA-PRESS \(button.rawValue) attempt \(attempt) accepted")
                    return
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        XCTFail("The dashboard never accepted a \(button.rawValue) press",
                file: file, line: line)
    }
    /// A field read out of the accessibility tree can still be the snapshot
    /// from before the press it followed, so a press that did step reports the
    /// old value once and the new one a moment later. Wait for the value the
    /// press is meant to produce instead of believing one read.
    private func waitForField(_ name: String, _ expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        var seen = field(name)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, seen != expected {
            Thread.sleep(forTimeInterval: 0.3)
            seen = field(name)
        }
        XCTAssertEqual(seen, expected, "\(name) never reached \(expected); state is \(rawState())",
                       file: file, line: line)
    }
    /// For a press whose point is that nothing moves: wait until the dial has
    /// published again, so the read afterwards is not the pre-press snapshot.
    private func waitForDialPublish(since beat: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, field("dialbeat") == beat {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertNotEqual(field("dialbeat"), beat, "The dial published nothing after the press",
                          file: file, line: line)
    }
    /// Presses and waits for the dashboard's focus to leave `origin`, without
    /// pinning the destination: which zone rows a household has is its business.
    @discardableResult
    private func pressMovingFocus(_ button: XCUIRemote.Button, from origin: String,
                                  file: StaticString = #filePath, line: UInt = #line) -> String {
        for attempt in 1...3 {
            send(button)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                let landed = field("focus")
                if !landed.isEmpty, landed != origin {
                    print("NOVA-PRESS \(button.rawValue) attempt \(attempt) landed \(landed)")
                    return landed
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        XCTFail("\(button.rawValue) never moved focus off \(origin)", file: file, line: line)
        return ""
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOrbIsReachableAndQuickDialCancelsWithoutSending() {
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        report("after first right")
        expectStateFocus("__quick-lights")
        press(.select, expecting: "editing=action:__quick/lights")
        // Preview only, cancelled inside the encoder's idle window: this test
        // never commits a household command.
        pressCounting(.right)
        report("after edit right")
        XCTAssertEqual(field("focus"), "action:__quick/lights",
                       "Adjusting a channel must not travel")
        XCTAssertEqual(field("editing"), "action:__quick/lights",
                       "Adjusting a channel must stay in the dial's edit")
        expectStateFocus("__quick-lights")
        press(.menu, expecting: "editing=nil")
        report("after cancel")
        XCTAssertEqual(field("focus"), "action:__quick/lights",
                       "Back cancels the draft, it does not move focus")
        expectStateFocus("__quick-lights")
        press(.left, expecting: "focus=action:__orb/dial")
        expectStateFocus("__orb-dial")
        capture("Orb reachable after editing")
    }

    func testOnePressMovesOneItemAndBothGroupsStayOpen() {
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        report("right 1")
        expectStateFocus("__quick-lights")
        // The end of a panel: the next swipe lands on the next panel's list, with
        // that panel's header tab skipped on the way in.
        press(.right, expecting: "focus=child:")
        report("right 2")
        // The swipe lands on the selected room, which an earlier test may have left
        // anywhere in the list: step toward the side that has a neighbour, and back.
        let row = field("focus")
        let (away, back): (XCUIRemote.Button, XCUIRemote.Button) = row == "child:everything" ? (.down, .up) : (.up, .down)
        let nextRow = pressMovingFocus(away, from: row)
        XCTAssertTrue(nextRow.hasPrefix("child:"), "A zone row's neighbour is a zone row, got \(nextRow)")
        press(back, expecting: "focus=" + row)
        press(.right, expecting: "focus=brightness:")
        report("right 3")
        press(.right, expecting: "focus=section:")
        report("right 4")
        capture("Home and Systems independent")
    }

    /// Walks one press at a time without asserting, printing the dashboard's own
    /// state at every step. Not part of the suite's verdict: it exists to
    /// diagnose a failing step in a single run.
    func testDiagnosticTrail() {
        continueAfterFailure = true
        state("at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        report("right 1")
        press(.select, expecting: "editing=action:__quick/lights")
        report("select")
        Thread.sleep(forTimeInterval: 3)
        state("select +3s")
        pressCounting(.right)
        report("edit right")
        pressCounting(.up)
        report("edit up")
        press(.menu, expecting: "editing=nil")
        report("menu")
        Thread.sleep(forTimeInterval: 2)
        state("menu +2s")
        press(.left, expecting: "focus=action:__orb/dial")
        report("left 1")
        capture("Diagnostic trail end")
    }

    // MARK: - Dials in 2026-09-20's terms: a latched target, rings then modes

    /// Writes a PNG beside the test log so the look of a state can be checked
    /// without a second run; XCUI screenshots otherwise land in the result
    /// bundle, where nothing reads them cheaply.
    private func shoot(_ name: String) {
        let url = URL(fileURLWithPath: "/tmp/nova-shots/\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        print("NOVA-SHOT \(url.path)")
    }

    /// An unlocked dial is a lease, not a mode. Inside the lease a pause changes
    /// nothing; when it expires the dial applies its draft and releases itself,
    /// exactly as a second click does (Adeline, 2026-09-21 — the
    /// hold-until-clicked rule of 2026-09-20 is superseded; the expiry half is
    /// `testUnlockedDialAppliesItsDraftWhenTheLeaseExpires`).
    func testUnlockedDialHoldsItsTargetForTheLeaseAndAppliesItOnASecondClick() {
        relaxDialLease(seconds: "60")
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        press(.select, expecting: "editing=action:__quick/lights")
        shoot("dial-unlocked")
        Thread.sleep(forTimeInterval: 7)
        XCTAssertEqual(field("editing"), "action:__quick/lights",
                       "A pause inside the lease must not release the dial")
        XCTAssertEqual(field("focus"), "action:__quick/lights",
                       "A pause must not move the swipe target either")
        XCTAssertEqual(field("last"), "none", "Nothing is applied while the lease is open")
        let beforeTurn = field("dialbeat")
        pressCounting(.up)
        waitForDialPublish(since: beforeTurn)
        let turnedUp = field("value")
        XCTAssertEqual(field("editing"), "action:__quick/lights",
                       "Adjusting still holds the target")
        let afterUp = field("dialbeat")
        pressCounting(.down)
        waitForDialPublish(since: afterUp)
        XCTAssertNotEqual(field("value"), turnedUp,
                          "Up and down must turn the dial the latch is on, not only arrive inside it")
        XCTAssertEqual(field("editing"), "action:__quick/lights",
                       "Adjusting the other way still holds the target")
        expectStateFocus("__quick-lights")
        press(.select, expecting: "editing=nil")
        XCTAssertEqual(field("focus"), "action:__quick/lights",
                       "A second click releases the dial and leaves the target on it")
        XCTAssertEqual(field("last"), "select-tap+commit",
                       "A second click applies the draft")
        XCTAssertEqual(field("channel"), "", "Releasing clears the published dial state")
        capture("Latched dial released by a second click")
    }

    /// The lease's other ending: no input at all for the household's five
    /// seconds, and the dial applies what it is showing and locks again — with
    /// the swipe target still on it, so the next press starts where it left off.
    /// The dial is turned up and back down first, so the draft returns to the
    /// value it opened on and the commit this test waits for sends the household
    /// nothing.
    func testUnlockedDialAppliesItsDraftWhenTheLeaseExpires() {
        relaxDialLease(seconds: "5")
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        press(.select, expecting: "editing=action:__quick/lights")
        let beforeTurn = field("dialbeat")
        pressCounting(.up)
        waitForDialPublish(since: beforeTurn)
        let afterUp = field("dialbeat")
        pressCounting(.down)
        waitForDialPublish(since: afterUp)
        // No input from here: only the lease can end the edit.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, field("editing") != "nil" {
            Thread.sleep(forTimeInterval: 0.5)
        }
        state("after the lease expired")
        XCTAssertEqual(field("editing"), "nil", "Five seconds with no input must release the dial")
        XCTAssertEqual(field("last"), "idle+commit",
                       "The lease applies the draft; it does not discard it")
        XCTAssertEqual(field("focus"), "action:__quick/lights",
                       "Releasing the dial leaves the swipe target on it")
        XCTAssertEqual(field("channel"), "", "Releasing clears the published dial state")
        capture("Dial released by its idle lease")
    }

    /// An unlocked dial keeps the swipe target: every
    /// direction is that dial's own step, none of them is travel (Adeline,
    /// 2026-09-21 — a swipe used to leave the unlocked ring and edit nothing).
    func testAnUnlockedDialKeepsTheSwipeTarget() {
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        press(.select, expecting: "editing=action:__quick/lights")
        for button in [XCUIRemote.Button.right, .left, .up, .down] {
            let before = field("dialbeat")
            pressCounting(button)
            waitForDialPublish(since: before)
            XCTAssertEqual(field("focus"), "action:__quick/lights",
                           "A \(button.rawValue) swipe off an unlocked dial must stay on it")
            XCTAssertEqual(field("editing"), "action:__quick/lights",
                           "A \(button.rawValue) swipe off an unlocked dial must step the dial")
        }
        press(.menu, expecting: "editing=nil")
        capture("Unlocked dial holds the swipe target")
    }

    /// The engine's focused view is the view tvOS delivers the next press to. A
    /// highlight on one control with the engine's focus on *another* is a remote
    /// that selects the wrong thing — the state the household hit on 2026-09-22
    /// ("I can't select any menu elements, focus is locking on to dials even if I
    /// don't click on them"). Every other test here asserts only the app's own
    /// published focus, which cannot see that difference, so this one walks a
    /// route and requires the engine never to be on a control the band is not
    /// highlighting.
    ///
    /// It deliberately does not require the engine to *report* the highlighted
    /// one: on this app the OS reports no focused element at all for a zone row
    /// even while that row is the app's focus and Select on it works (see
    /// `testSelectingAZoneRowMakesItTheSelectedRoom`), so "nothing" is tolerated
    /// and "something else" is the failure.
    func testTheEngineNeverHoldsFocusOnAControlTheBandIsNotHighlighting() {
        expectState("focus=action:__orb/dial", "at rest")
        let route: [(XCUIRemote.Button, String)] = [
            (.right, "focus=action:__quick/lights"),
            (.right, "focus=child:"),
            (.right, "focus=brightness:"),
            (.right, "focus=section:"),
            (.left, "focus=brightness:"),
            (.left, "focus=child:")
        ]
        for (button, expectation) in route {
            press(button, expecting: expectation)
            expectNoStrayEngineFocus(highlighting: Self.accessibilityID(forFocusToken: field("focus")))
        }
        capture("Engine never holds a control the band is not highlighting")
    }

    /// Polls for a few seconds after a press: whatever the engine's focused view
    /// is, it must never be a control other than the one the band highlights.
    private func expectNoStrayEngineFocus(highlighting id: String, file: StaticString = #filePath, line: UInt = #line) {
        let others = knownTargets + homeRows
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let strays = others.filter { $0 != id && focused($0) }
            XCTAssertTrue(strays.isEmpty,
                          "the engine holds \(strays) while the band highlights \(id); os=\(focusedIDs())",
                          file: file, line: line)
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("NOVA-ENGINE \(id): os=\(focusedIDs())")
    }

    /// Pressing Select on a menu row has to make that row the selected room. The
    /// suite presses Select on dials throughout, but never on a row — so nothing
    /// measured the household's "I can't select any menu elements" at all, and
    /// `testTheEnginesFocusedViewIsTheControlTheBandHighlights` shows the engine
    /// reporting *no* focused view on those rows while the band highlights one.
    /// A row that the system will not hand a press to is a row that cannot be
    /// selected, whatever the highlight says.
    func testSelectingAZoneRowMakesItTheSelectedRoom() {
        expectState("focus=action:__orb/dial", "at rest")
        press(.right, expecting: "focus=action:__quick/lights")
        press(.right, expecting: "focus=child:")
        // Sit on a row that is not the current selection, so the Select press has
        // something to change.
        if field("focus") == "child:" + field("home") {
            // Step to a neighbour that exists: down from the first row, up from any other.
            pressMovingFocus(field("focus") == "child:everything" ? .down : .up, from: field("focus"))
        }
        let row = field("focus")
        XCTAssertTrue(row.hasPrefix("child:"), "A zone row must hold focus, got \(row)")
        let rowID = String(row.dropFirst("child:".count))
        XCTAssertNotEqual(rowID, field("home"), "The focused row is the one the press must change")
        remote.press(.select)
        waitForField("home", rowID)
        XCTAssertEqual(field("home"), rowID, "Select on a menu row must select that room")
        capture("Menu row selected")
    }

    /// The suite's default holds the dial lease open, because XCUI can spend
    /// longer than five seconds resolving one element on this never-idle app and
    /// a lease expiring mid-assertion would be the harness's doing, not the
    /// app's. A test that is *about* the lease asks for a real one and relaunches
    /// (see `UITestHarness.dialIdleCommit`).
    private func relaxDialLease(seconds: String) {
        app.terminate()
        app.launchEnvironment["NOVA_DIAL_IDLE_COMMIT_S"] = seconds
        app.launch()
        XCTAssertTrue(element("__orb-dial").waitForExistence(timeout: 60),
                      "The orb must appear once state arrives")
    }

    /// Left/right walks the rings outermost inward and then the mode lights, and
    /// both ends hold: the timer dial is the smallest case of that order, with
    /// its duration ring to the left of its type mode.
    func testDialSwipesStepFromTheRingsOutToTheModesAndStop() {
        expectState("focus=action:__orb/dial", "at rest")
        for _ in 1...8 where !field("focus").hasPrefix("section:") {
            pressMovingFocus(.right, from: field("focus"))
        }
        XCTAssertTrue(field("focus").hasPrefix("section:"), "The systems list is reachable")
        for _ in 1...8 where field("focus") != "section:__timers" {
            pressMovingFocus(.down, from: field("focus"))
        }
        XCTAssertEqual(field("focus"), "section:__timers", "The Reminders row is in the systems list")
        press(.right, expecting: "focus=action:__timers/timer")
        press(.select, expecting: "editing=action:__timers/timer")
        shoot("timer-dial-unlocked")
        XCTAssertEqual(field("steps"), "duration,icon",
                       "The duration ring is stepped onto before the type mode")
        XCTAssertEqual(field("channel"), "duration", "A dial opens on its left-most step")
        pressCounting(.right)
        waitForField("channel", "icon")                      // steps onto the mode
        let afterStep = field("dialbeat")
        pressCounting(.right)
        waitForDialPublish(since: afterStep)
        XCTAssertEqual(field("channel"), "icon", "The last mode holds instead of wrapping")
        pressCounting(.left)
        waitForField("channel", "duration")                  // and back onto the ring
        let afterBack = field("dialbeat")
        pressCounting(.left)
        waitForDialPublish(since: afterBack)
        XCTAssertEqual(field("channel"), "duration", "The outermost ring holds instead of wrapping")
        XCTAssertEqual(field("editing"), "action:__timers/timer", "Stepping never leaves the dial")
        press(.menu, expecting: "editing=nil")
        capture("Timer dial stepped ring then mode")
    }

    /// Leaving the visualiser comes back to the Phonoscope row it was opened from,
    /// not to the orb (Adeline, 2026-10-16).
    func testLeavingTheVisualiserReturnsToThePhonoscopeRow() {
        expectState("focus=action:__orb/dial", "at rest")
        for _ in 1...8 where !field("focus").hasPrefix("section:") {
            pressMovingFocus(.right, from: field("focus"))
        }
        for _ in 1...10 where field("focus") != "section:__phonoscope" {
            pressMovingFocus(.down, from: field("focus"))
        }
        XCTAssertEqual(field("focus"), "section:__phonoscope", "The Phonoscope row is reachable")
        remote.press(.select)
        let gone = Date().addingTimeInterval(10)
        while Date() < gone, element("__nova-focus-state").exists { Thread.sleep(forTimeInterval: 0.3) }
        Thread.sleep(forTimeInterval: 2)
        remote.press(.menu)
        XCTAssertTrue(element("__nova-focus-state").waitForExistence(timeout: 15), "The band comes back")
        waitForField("focus", "section:__phonoscope")
        XCTAssertEqual(field("focus"), "section:__phonoscope", "Back from the visualiser, focus is on its row")
        capture("Back on the Phonoscope row")
    }

    /// The phonoscope button is a row of the systems list, under Reminders, and
    /// the bottom row that list stops on (Adeline, 2026-09-20).
    func testPhonoscopeIsTheLastRowOfTheSystemsList() {
        expectState("focus=action:__orb/dial", "at rest")
        for _ in 1...8 where !field("focus").hasPrefix("section:") {
            pressMovingFocus(.right, from: field("focus"))
        }
        for _ in 1...10 where field("focus") != "section:__phonoscope" {
            pressMovingFocus(.down, from: field("focus"))
        }
        XCTAssertEqual(field("focus"), "section:__phonoscope",
                       "Swipe down the systems list to reach the phonoscope")
        shoot("phonoscope-row-focused")
        // The row is drawn by the same control as the systems above it, so it
        // carries that control's section- identifier. The TV's own focus
        // attribute is not dependable for these rows (see the note above), so
        // this checks the identified row is there and the app's own state, which
        // line 373 already asserted, says focus is on it.
        XCTAssertTrue(element("section-__phonoscope").exists,
                      "The phonoscope row must be an identified row control")
        pressCounting(.down)
        XCTAssertEqual(field("focus"), "section:__phonoscope",
                       "The bottom row of the list is the end of the list")
        capture("Phonoscope under Systems")
    }
}
