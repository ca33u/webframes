//
//  WebFramesSmokeUITests.swift
//  webframesUITests
//
//  End-to-end smoke tests that drive the app from outside the sandbox
//  (XCUITest runs unsandboxed) and assert the launch → new-project →
//  save-toast path works as a user would experience it.
//
//  Element anchors used here are accessibility identifiers set in the
//  app source (StartWindowController / DocumentWindowController /
//  ToastView). If a test can't find its element, verify the identifier
//  is still set on the matching view.
//
//  Projects directory pollution: each test snapshots the host app's
//  `.webframes` files on setUp and deletes any new ones on tearDown,
//  so clean passes don't leave residue. A crashed test run may leak a
//  single file — those will accumulate over time and can be removed
//  manually from
//    ~/Library/Containers/app.essazanov.webframes/Data/Library/…
//

import XCTest

@MainActor
final class WebFramesSmokeUITests: XCTestCase {

    private var app: XCUIApplication!
    private var projectsBeforeTest: Set<URL> = []

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        // Stopping on the first failure keeps the tail of the test from
        // compounding errors that obscure the real cause.
        continueAfterFailure = false

        projectsBeforeTest = Self.snapshotProjectFiles()

        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil

        // Delete any `.webframes` files that appeared during the test.
        let after = Self.snapshotProjectFiles()
        for url in after.subtracting(projectsBeforeTest) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Tests

    /// Baseline: the app launches and the Start window — with its
    /// primary CTA — is on screen. If this fails, nothing else can run.
    func testStartWindowShowsNewProjectButton() {
        let start = app.windows["startWindow"]
        XCTAssertTrue(start.waitForExistence(timeout: 5),
                      "Start window did not appear within 5s of launch")

        let newBtn = start.buttons["newProjectButton"]
        XCTAssertTrue(newBtn.exists, "New Project button not found on Start window")
        XCTAssertTrue(newBtn.isHittable, "New Project button is not hittable")
    }

    /// A plain relaunch must not reopen the document that was visible when
    /// the previous process terminated. Users choose a project explicitly
    /// from the Start window.
    func testRelaunchReturnsToProjectPicker() {
        let start = app.windows["startWindow"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.buttons["newProjectButton"].click()
        XCTAssertTrue(app.windows["documentWindow"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(app.windows["startWindow"].waitForExistence(timeout: 5),
                      "Project picker did not appear after relaunch")
        XCTAssertFalse(app.windows["documentWindow"].exists,
                       "Previous project reopened without an explicit choice")
    }

    /// Clicking New Project must open a document window with the
    /// centered title-field present.
    func testNewProjectOpensDocumentWindow() {
        let start = app.windows["startWindow"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))

        start.buttons["newProjectButton"].click()

        let doc = app.windows["documentWindow"]
        XCTAssertTrue(doc.waitForExistence(timeout: 5),
                      "Document window did not appear after clicking New Project")

        // The title field is the only editable titlebar element — its
        // presence confirms the canvas host wired up correctly.
        let titleField = doc.textFields["documentTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2),
                      "Document title field did not render")
    }

    /// File → Save must surface the "auto-save is on" toast. This
    /// exercises the menu → NSDocument.save(_:) → autosave callback →
    /// toast-show pipeline end-to-end.
    ///
    /// We click the menu item rather than synthesizing Cmd+S: the canvas
    /// is a WKWebView and typeKey-to-menu-equivalent has been observed
    /// to get eaten by the webview's event pipeline before AppKit's
    /// NSMenu.performKeyEquivalent sees it. Clicking the menu item is
    /// the same code path a real user hits (via menu or key-equivalent)
    /// but bypasses the webview entirely.
    func testCmdSShowsAutoSaveToast() {
        let start = app.windows["startWindow"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.buttons["newProjectButton"].click()

        let doc = app.windows["documentWindow"]
        XCTAssertTrue(doc.waitForExistence(timeout: 5))

        // Ensure the doc is frontmost so File → Save targets its document.
        doc.click()

        clickMenuItem(menu: "File", item: "Save")

        // Match by the accessibility identifier on the toast's label.
        // The outer ToastView's identifier ("toast") doesn't propagate
        // to the inner NSTextField — staticTexts looks at the label
        // element directly.
        let toast = doc.staticTexts["toastLabel"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3),
                      "Auto-save toast did not appear within 3s of File → Save")
        XCTAssertEqual(toast.value as? String,
                       "Auto-save is on — no need to save",
                       "Toast label text did not match expected message")
    }

    /// Closing a document window must bring the Start window back up —
    /// the app never quits on last-window-closed (see AppDelegate's
    /// `applicationShouldTerminateAfterLastWindowClosed`), so a
    /// window-less state here would strand the user.
    ///
    /// We intentionally don't assert that the project file lands on disk:
    /// `autosavesInPlace` treats never-mutated fresh docs as drafts and
    /// discards them on close, which is the desired UX (no empty Untitled
    /// clutter in Recent). File persistence is the canvas's job — first
    /// meaningful mutation calls `updateChangeCount(.changeDone)` and
    /// autosave takes over from there.
    func testClosingDocumentReturnsToStart() {
        let start = app.windows["startWindow"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))

        start.buttons["newProjectButton"].click()

        let doc = app.windows["documentWindow"]
        XCTAssertTrue(doc.waitForExistence(timeout: 5))

        doc.click()
        clickMenuItem(menu: "File", item: "Close")

        XCTAssertTrue(start.waitForExistence(timeout: 5),
                      "Start window did not return after closing the document")
    }

    // MARK: - Helpers

    /// Click a menu-bar item's submenu item (e.g. File → Save). Used in
    /// place of `typeKey(_:modifierFlags:)` for Cmd-key shortcuts that
    /// route through the menu: when the frontmost window hosts a
    /// WKWebView, typeKey has been observed to get consumed by the
    /// webview's event pipeline before AppKit's
    /// `NSMenu.performKeyEquivalent(with:)` gets to look at it.
    private func clickMenuItem(menu: String, item: String) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 3),
                      "App menu bar did not appear")
        let menuItem = menuBar.menuBarItems[menu]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Menu '\(menu)' did not appear in the menu bar")
        menuItem.click()
        let target = menuItem.menuItems[item]
        XCTAssertTrue(target.waitForExistence(timeout: 3),
                      "Menu item '\(menu) → \(item)' did not appear")
        target.click()
    }

    /// Returns every `.webframes` file currently in the host app's
    /// sandboxed projects directory. The UI test process is NOT
    /// sandboxed, so reading the host's container path directly works.
    private static func snapshotProjectFiles() -> Set<URL> {
        let dir = projectsDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(urls.filter { $0.pathExtension == "webframes" })
    }

    /// Host app's Application Support / Web Frames / Projects, read
    /// via the container path. Hard-coded bundle id matches the app
    /// target's `PRODUCT_BUNDLE_IDENTIFIER`.
    private static func projectsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/app.essazanov.webframes/Data/Library/Application Support/Web Frames/Projects",
                isDirectory: true
            )
    }
}
