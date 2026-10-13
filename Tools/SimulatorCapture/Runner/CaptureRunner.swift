import XCTest
import Darwin

/// Web Frames' own runner. Only typed actions are accepted; no user code or shell commands.
final class CaptureRunner: XCTestCase {
    struct Recipe: Decodable {
        let appBundleID: String
        let restartApp: Bool
        let deeplink: String?
        let steps: [Step]
        let testState: TestState?
    }
    struct Step: Decodable { let action: String; let value: String }
    struct TestState: Decodable {
        let name: String; let account: String; let data: [String: String]; let theme: String
        let launchArguments: [String]; let preparation: [Step]; let readySelector: String
    }

    @MainActor func testCapture() throws {
        continueAfterFailure = false
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["WF_CAPTURE_RECIPE"])
        let recipe = try JSONDecoder().decode(Recipe.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
        let app = XCUIApplication(bundleIdentifier: recipe.appBundleID)
        if let state = recipe.testState {
            app.launchArguments = state.launchArguments
            app.launchEnvironment = ["WEBFRAMES_TEST_STATE": state.name, "WEBFRAMES_TEST_ACCOUNT": state.account,
                "WEBFRAMES_TEST_DATA": String(decoding: try JSONSerialization.data(withJSONObject: state.data), as: UTF8.self),
                "WEBFRAMES_TEST_THEME": state.theme]
        }
        if recipe.restartApp || recipe.testState != nil { app.terminate(); app.launch() } else { app.activate() }
        if let state = recipe.testState {
            try runSteps(state.preparation, app: app)
            XCTAssertTrue(matches(app, value: state.readySelector).firstMatch.waitForExistence(timeout: 15), "Test state is not ready")
            XCTAssertTrue(matches(app, value: state.readySelector).allElementsBoundByIndex.contains { $0.isHittable }, "Test state is covered")
        }
        if let link = recipe.deeplink, !link.isEmpty {
            if #available(iOS 16.4, *) { app.open(try XCTUnwrap(URL(string: link))) }
            else { throw NSError(domain: "WebFramesCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Deeplinks require iOS 16.4 or newer."]) }
        }
        if let session = ProcessInfo.processInfo.environment["WF_RECORDING_ID"] {
            let live = ProcessInfo.processInfo.environment["WF_CAPTURE_LIVE"] == "1"
            if live { try runSteps(recipe.steps, app: app) }
            try record(app: app, session: session, live: live)
            return
        }
        try runSteps(recipe.steps, app: app)
        XCTAssertEqual(app.state, .runningForeground, "The selected app must be visible before capture.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "WebFramesCapture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func runSteps(_ steps: [Step], app: XCUIApplication) throws {
        for (index, step) in steps.enumerated() {
            try XCTContext.runActivity(named: "Step \(index + 1): \(step.action)\(step.action == "type" ? "" : " " + step.value)") { _ in
                switch step.action {
                case "tap", "wait":
                    let matches = matches(app, value: step.value)
                    XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "Element not found: \(step.value)")
                    if step.action == "tap" {
                        // Labels can also appear on child text; choose the unique hittable match.
                        try target(app, value: step.value).tap()
                    } else {
                        XCTAssertTrue(matches.allElementsBoundByIndex.contains(where: { $0.isHittable }), "Element is covered or offscreen: \(step.value)")
                    }
                case "type": app.typeText(step.value)
                case "swipeUp": app.swipeUp()
                case "swipeDown": app.swipeDown()
                default: XCTFail("Unsupported action: \(step.action)")
                }
            }
        }
    }

    @MainActor private func matches(_ app: XCUIApplication, value: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@ OR placeholderValue == %@", value, value, value))
    }
    @MainActor private func target(_ app: XCUIApplication, value: String) throws -> XCUIElement {
        let found = matches(app, value: value).allElementsBoundByIndex.filter { $0.isHittable }
        let actionable = found.filter { [.button, .link, .textField, .secureTextField, .textView, .switch, .cell].contains($0.elementType) }
        let candidates = actionable.isEmpty ? found : actionable
        guard candidates.count == 1, let element = candidates.first else { throw failure("Choose a control with a unique label or accessibility identifier.") }
        return element
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "WebFramesRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    struct Command: Decodable { let id: String; let action: String; let value: String?; let x: Double?; let y: Double? }
    struct Node: Encodable {
        let selector: String; let label: String; let x: Double; let y: Double; let w: Double; let h: Double
        let editable: Bool; let secure: Bool
    }
    struct Reply: Encodable { let id: String; let nodes: [Node]; let action: String?; let value: String?; let error: String? }

    @MainActor private func nodes(_ app: XCUIApplication) throws -> [Node] {
        let frame = app.frame
        guard frame.width > 0, frame.height > 0 else { throw failure("The app has no visible screen.") }
        var result: [Node] = []
        func collect(_ element: any XCUIElementSnapshot, depth: Int) {
            guard depth < 80, result.count < 1_000 else { return }
            let bounds = element.frame.intersection(frame)
            let editable = [.textField, .secureTextField, .textView].contains(element.elementType)
            let selector = !element.identifier.isEmpty ? element.identifier : (!element.label.isEmpty ? element.label : (element.placeholderValue ?? ""))
            let recordable = ![.application, .window, .scrollView, .collectionView, .table].contains(element.elementType)
                && (element.elementType != .other || !element.label.isEmpty)
            if recordable, element.isEnabled, !bounds.isNull, bounds.width > 0, bounds.height > 0,
                !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selector.utf8.count <= 4_096 {
                result.append(.init(selector: selector, label: String((element.label.isEmpty ? (element.placeholderValue ?? selector) : element.label).prefix(500)),
                    x: (bounds.minX-frame.minX)/frame.width, y: (bounds.minY-frame.minY)/frame.height,
                    w: bounds.width/frame.width, h: bounds.height/frame.height, editable: editable, secure: element.elementType == .secureTextField))
            }
            for child in element.children { collect(child, depth: depth + 1) }
        }
        collect(try app.snapshot(), depth: 0)
        return result
    }

    @MainActor private func record(app: XCUIApplication, session: String, live: Bool = false) throws {
        guard UUID(uuidString: session) != nil else { throw failure("Invalid recording session.") }
        let fm = FileManager.default
        let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WebFramesRecording-" + session)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        print("WF_RECORDING_CHANNEL " + directory.path); fflush(stdout)
        defer { try? fm.removeItem(at: directory) }
        let commandFile = directory.appendingPathComponent("command.json")
        var secureInput = false
        var editableInput = false
        func reply(_ id: String, action: String? = nil, value: String? = nil, error: String? = nil) throws {
            guard app.state == .runningForeground else { throw failure("The selected app is not in the foreground. Dismiss system dialogs first.") }
            let items = live ? [] : try nodes(app)
            let screenshot = try XCTUnwrap(XCUIScreen.main.screenshot().image.pngData())
            if live && app.state != .runningForeground { throw failure("The selected app left the foreground.") }
            try screenshot.write(to: directory.appendingPathComponent("screen.png"), options: .atomic)
            if id != "live" {
                try JSONEncoder().encode(Reply(id: id, nodes: items, action: action, value: value, error: error)).write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
        try reply("ready")
        print("WF_RECORDING_READY"); fflush(stdout)
        let end = Date().addingTimeInterval(900)
        var count = 0
        while Date() < end {
            if live {
                try reply("live")
                Thread.sleep(forTimeInterval: 0.3)
            }
            guard fm.fileExists(atPath: commandFile.path) else { Thread.sleep(forTimeInterval: live ? 0 : 0.1); continue }
            let data = try Data(contentsOf: commandFile); try fm.removeItem(at: commandFile)
            guard data.count <= 32_000 else { throw failure("Invalid recording command.") }
            let command = try JSONDecoder().decode(Command.self, from: data)
            guard UUID(uuidString: command.id) != nil else { throw failure("Invalid recording command id.") }
            if command.action == "stop" { return }
            do {
                guard command.action == "refresh" || count < 30 else { throw failure("Recording limit reached (30 actions).") }
                guard app.state == .runningForeground else { throw failure("Return to the selected app before recording.") }
                var value: String? = nil
                switch command.action {
                case "tap":
                    guard let x = command.x, let y = command.y, (0...1).contains(x), (0...1).contains(y) else { throw failure("Tap inside the app screen.") }
                    let candidates = try nodes(app).filter { x >= $0.x && x <= $0.x+$0.w && y >= $0.y && y <= $0.y+$0.h }.sorted { $0.w*$0.h < $1.w*$1.h }
                    var selected: XCUIElement?
                    for item in candidates {
                        if let element = try? target(app, value: item.selector), element.frame.contains(CGPoint(x: app.frame.minX+x*app.frame.width, y: app.frame.minY+y*app.frame.height)) {
                            selected = element; value = item.selector; break
                        }
                    }
                    guard let selected else { throw failure("This control needs a unique accessibility label before it can be recorded.") }
                    if secureInput || app.secureTextFields.allElementsBoundByIndex.contains(where: { $0.isHittable }),
                        app.keyboards.allElementsBoundByIndex.contains(where: { $0.frame.intersects(selected.frame) }) {
                        throw failure("Password entry is not recorded.")
                    }
                    secureInput = selected.elementType == .secureTextField
                    editableInput = [.textField, .textView].contains(selected.elementType)
                    selected.tap()
                case "type":
                    guard !secureInput, app.secureTextFields.allElementsBoundByIndex.allSatisfy({ !$0.isHittable }) else { throw failure("Password entry is not recorded.") }
                    guard editableInput else { throw failure("Tap an editable field before typing.") }
                    guard let text = command.value, !text.isEmpty, text.count <= 2_000 else { throw failure("Enter 1–2000 characters.") }
                    app.typeText(text); value = text
                case "swipeUp": app.swipeUp()
                case "swipeDown": app.swipeDown()
                case "refresh": break
                default: throw failure("Unsupported recording action.")
                }
                if command.action != "refresh" { count += 1 }
                try reply(command.id, action: command.action == "refresh" ? nil : command.action, value: value)
            } catch { try reply(command.id, error: error.localizedDescription) }
        }
        throw failure("Recording ended after 15 minutes. Start a new recording.")
    }
}
