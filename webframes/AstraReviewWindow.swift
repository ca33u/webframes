import AppKit
import WebKit
import UniformTypeIdentifiers

private struct CommentFixFrameEvidence: Codable {
    let frameID: String
    let label: String
    let beforeImage: String
    let afterImage: String
    let pixelsChanged: Bool
}

@MainActor
final class AstraReviewWindow: NSWindowController, NSWindowDelegate {
    private weak var documentController: DocumentWindowController?
    private weak var project: WebFramesDocument?
    private let referencePicker = NSPopUpButton()
    private let actualPicker = NSPopUpButton()
    private let folderLabel = NSTextField(labelWithString:"Not selected")
    private let connectionLabel = NSTextField(labelWithString:"Connect your signed-in \(AgentProvider.current.name). No API key needed.")
    private let statusLabel = NSTextField(wrappingLabelWithString:"Choose two frames and a source folder, or open the sample project.")
    private let output = NSTextView()
    private let images = [NSImageView(),NSImageView(),NSImageView()]
    private var controls: [NSControl] = []
    private var analyzeButton: NSButton!
    private var applyButton: NSButton!
    private var undoButton: NSButton!
    private var cancelButton: NSButton!
    private var logButton: NSButton!
    private var workspace: AstraWorkspace?
    private var client: AstraCodexClient?
    private var task: Task<Void,Never>?
    private var artifacts: AstraRunArtifacts?
    private var proposal: AstraProposal?
    private var patch: AstraPatch?
    private var patches = AstraPatchService()
    private var commentFixProposal: CodexCommentFixProposal?
    private var commentFixPatch: CodexCommentFixPatch?
    private var commentFixes = CodexCommentFixService()
    private var reference: AstraCapture?
    private var before: AstraCapture?
    private var after: AstraCapture?
    private var analyzedFrameID: String?
    private var server: AstraDemoServer?
    private var demoFrameIDs: [String] = []
    private var demoRoot: URL?
    private let capture = AstraCaptureService()

    init(owner:DocumentWindowController,project:WebFramesDocument) {
        self.documentController = owner; self.project = project
        super.init(window:nil)
        buildUI(); refreshFrames(); updateButtons()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCodexConnection), name: CodexConnectionStore.changed, object: nil)
        refreshCodexConnection()
        owner.canvasHost.onFrameSelectionChanged = { [weak self] in self?.selectionUpdated() }
        selectionUpdated()
    }
    @available(*,unavailable) required init?(coder:NSCoder) { fatalError() }

    private func button(_ title:String,_ action:Selector,_ id:String) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; b.setAccessibilityIdentifier(id); return b
    }
    private let bar = WFGlassEffectContainerView()
    private let statusPopover = NSPopover()
    private var statusButton: NSButton!
    private var hasError = false
    private let pairLabel = NSTextField(labelWithString:"")
    private let setupPopover = NSPopover()
    private var reviewSheet: NSWindow?
    private var reviewButton: NSButton!
    private var swapButton: NSButton!
    private var selectedPair: [String] = []
    private var workspaceVisible = true
    private var commentFixFlowActive = false
    func setWorkspaceVisible(_ visible: Bool) { workspaceVisible = visible; updateBarVisibility() }
    private func updateBarVisibility() {
        let ids = Array((documentController?.canvasHost.selectedFrameIDs ?? []).suffix(2))
        let pairReady = ids.count == 2 && (selectedPair.isEmpty || Set(ids) == Set(selectedPair))
        bar.isHidden = !workspaceVisible || (!commentFixFlowActive && !pairReady)
        if bar.isHidden { setupPopover.close(); statusPopover.close() }
    }
    private var findingPins: [String:String] = [:]

    private func buildUI() {
        guard let host = documentController?.canvasHost else { return }
        bar.spacing = 8;bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        analyzeButton = button("Compare",#selector(analyze),"astraAnalyze")
        analyzeButton.font = .systemFont(ofSize:13,weight:.semibold)
        analyzeButton.controlSize = .large
        analyzeButton.heightAnchor.constraint(equalToConstant:40).isActive = true
        analyzeButton.widthAnchor.constraint(equalToConstant:104).isActive = true
        swapButton = iconButton("arrow.left.arrow.right","Swap reference",#selector(swapPair),"astraSwap")
        reviewButton = iconButton("doc.text.magnifyingglass","Review proposed fix",#selector(showReview),"astraReviewFix")
        undoButton = iconButton("arrow.uturn.backward","Undo fix",#selector(undo),"astraUndo")
        cancelButton = iconButton("xmark","Cancel",#selector(cancel),"astraCancel")
        let setup = iconButton("gearshape","Comparison settings",#selector(showSetup),"astraSetup")
        statusButton = iconButton("info","Comparison status",#selector(showStatus),"astraStatusDetails")
        let actions = NSStackView(views:[analyzeButton,swapButton,reviewButton,undoButton,cancelButton,statusButton,setup])
        actions.spacing = 8;actions.alignment = .centerY; actions.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView = actions
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo:host.centerXAnchor),bar.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-84),
            actions.leadingAnchor.constraint(equalTo:bar.leadingAnchor),actions.trailingAnchor.constraint(equalTo:bar.trailingAnchor),
            actions.topAnchor.constraint(equalTo:bar.topAnchor),actions.bottomAnchor.constraint(equalTo:bar.bottomAnchor)])
        statusLabel.font = .systemFont(ofSize:13);statusLabel.textColor = .labelColor;statusLabel.setAccessibilityIdentifier("astraStatus")
        let statusContent = NSStackView(views:[statusLabel]);statusContent.edgeInsets = NSEdgeInsets(top:16,left:18,bottom:16,right:18)
        statusLabel.widthAnchor.constraint(equalToConstant:300).isActive = true
        let statusVC = NSViewController();statusVC.view = statusContent
        statusPopover.contentViewController = statusVC;statusPopover.behavior = .transient
        applyButton = iconButton("checkmark","Apply reviewed fix",#selector(approveFix),"astraApply")
        // Comparison settings: one row per thing Compare depends on, each
        // with a plain-text action, instead of unlabeled icon buttons.
        logButton = textButton("Show in Finder",#selector(showEvidence),"astraEvidence")
        let connect = textButton("Settings…",#selector(connectCodex),"astraConnect")
        let demo = textButton("Open",#selector(openSampleProject),"astraDemo")
        let folder = textButton("Choose…",#selector(chooseFolder),"astraFolder")
        let sampleLabel = NSTextField(labelWithString:"A ready-made page and reference to try Compare")
        let evidenceLabel = NSTextField(labelWithString:"Screenshots, proposal and diff of the last run")
        let settings = NSGridView(views:[
            [rowTitle("Coding agent"), connectionLabel, connect],
            [rowTitle("Source folder"), folderLabel, folder],
            [rowTitle("Sample project"), sampleLabel, demo],
            [rowTitle("Run evidence"), evidenceLabel, logButton],
        ])
        settings.rowSpacing = 14; settings.columnSpacing = 14
        settings.rowAlignment = .firstBaseline
        settings.column(at: 2).xPlacement = .trailing
        settings.translatesAutoresizingMaskIntoConstraints = false
        for label in [connectionLabel,folderLabel,sampleLabel,evidenceLabel] {
            label.font = .systemFont(ofSize:12); label.textColor = WFDesign.text2
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant:260).isActive = true
        }
        let settingsContainer = NSView()
        settingsContainer.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo:settingsContainer.leadingAnchor,constant:18),
            settings.trailingAnchor.constraint(equalTo:settingsContainer.trailingAnchor,constant:-18),
            settings.topAnchor.constraint(equalTo:settingsContainer.topAnchor,constant:18),
            settings.bottomAnchor.constraint(equalTo:settingsContainer.bottomAnchor,constant:-18),
        ])
        let vc = NSViewController(); vc.view = settingsContainer; setupPopover.contentViewController = vc; setupPopover.behavior = .transient
        controls = [connect,demo,folder,swapButton]
        output.isEditable = false;output.isSelectable = true;output.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        output.autoresizingMask = [.width];output.isVerticallyResizable = true;output.textContainer?.widthTracksTextView = true
        output.textContainerInset = NSSize(width:12,height:12);output.setAccessibilityIdentifier("astraReview")
    }
    private func textButton(_ title:String,_ action:Selector,_ id:String) -> NSButton {
        let b = button(title,action,id); b.controlSize = .regular; return b
    }
    private func rowTitle(_ text:String) -> NSTextField {
        let label = NSTextField(labelWithString:text)
        label.font = .systemFont(ofSize:12,weight:.semibold); label.textColor = WFDesign.text
        return label
    }
    private func iconButton(_ symbol:String,_ label:String,_ action:Selector,_ id:String) -> NSButton {
        let b = button("",action,id);b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label)
        b.contentTintColor = .labelColor
        b.imagePosition = .imageOnly;b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:15,weight:.medium)
        b.setAccessibilityLabel(label);b.toolTip = label;b.controlSize = .large
        b.widthAnchor.constraint(equalToConstant:40).isActive = true;b.heightAnchor.constraint(equalToConstant:40).isActive = true
        return b
    }
    @objc private func showStatus() {statusPopover.show(relativeTo:statusButton.bounds,of:statusButton,preferredEdge:.minY)}
    func containsControl(at point:NSPoint) -> Bool {
        !bar.isHidden && bar.bounds.contains(bar.convert(point,from:nil))
    }
    @objc private func showSetup() {setupPopover.show(relativeTo:bar.bounds,of:bar,preferredEdge:.minY)}
    func selectionUpdated() {
        updateBarVisibility()
        guard task == nil,patch == nil,commentFixPatch == nil,
              patches.applied == nil,commentFixes.applied == nil else {return}
        let ids = Array((documentController?.canvasHost.selectedFrameIDs ?? []).suffix(2))
        if ids.count == 2 {
            if Set(ids) != Set(selectedPair) {
                selectedPair = ids
                if project?.workspace.frames.first(where:{$0.id == ids[1]})?.isImage == true {selectedPair.reverse()}
            }
            refreshFrames(); select(referencePicker,id:selectedPair[0]);select(actualPicker,id:selectedPair[1]); updatePairLabel()
        } else {
            selectedPair = []; pairLabel.stringValue = "Shift-click two frames to compare"
        }
        updateBarVisibility()
        updateButtons()
    }
    private func updatePairLabel() {
        let frames = project?.workspace.frames ?? []
        let labels = selectedPair.map { id in frames.first(where:{$0.id == id})?.label ?? "Frame" }
        if labels.count == 2 {
            let direction = "Reference: \(labels[0]) → Implementation: \(labels[1])"
            pairLabel.stringValue = direction;swapButton.toolTip = "Swap reference\n" + direction
            analyzeButton.toolTip = direction;reviewButton.toolTip = "Review proposed fix\n" + direction
        }
    }
    @objc private func swapPair() {
        guard selectedPair.count == 2 else {return}; selectedPair.reverse()
        select(referencePicker,id:selectedPair[0]); select(actualPicker,id:selectedPair[1]);updatePairLabel()
    }
    @objc private func showReview() {
        guard let owner = documentController?.window, reviewSheet == nil,
              patch != nil || commentFixPatch != nil else {return}
        let sheet = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:450),styleMask:[.titled],backing:.buffered,defer:false)
        WFTheme.apply(to: sheet)
        let isCommentFix = commentFixPatch != nil
        sheet.title = isCommentFix ? "Review \(AgentProvider.current.name) changes" : "Review proposed changes"
        let stack = NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top:18,left:18,bottom:18,right:18);stack.frame = sheet.contentView!.bounds;stack.autoresizingMask = [.width,.height]
        sheet.contentView!.addSubview(stack)
        let reviewMessage = isCommentFix
            ? "Review every proposed change before writing to the project. Applying reloads the project frames; comments remain open until you verify and resolve them."
            : "Review these changes before writing to your source folder. Applying reloads the frame and checks the result."
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:reviewMessage))
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.documentView = output
        scroll.widthAnchor.constraint(equalToConstant:624).isActive = true;scroll.heightAnchor.constraint(equalToConstant:320).isActive = true
        output.frame = NSRect(x:0,y:0,width:624,height:320);stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(NSStackView(views:[iconButton("arrow.left","Back to canvas",#selector(closeReview),"astraBack"),applyButton]))
        reviewSheet = sheet;owner.beginSheet(sheet)
    }
    @objc private func closeReview() {if let sheet = reviewSheet {documentController?.window?.endSheet(sheet);reviewSheet = nil}}
    @objc private func approveFix() {
        closeReview()
        guard let patch = commentFixPatch else { apply(); return }
        guard !patch.configEntries.isEmpty else { applyCommentFix(configConfirmed: false); return }
        // Build and dependency files can run code on install or build; ask
        // again, naming them, instead of folding them into the diff approval.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply Changes to Build Configuration?"
        alert.informativeText = "This fix edits " + patch.configEntries.map(\.path).joined(separator: ", ")
            + ". These files can run code when the project installs dependencies or builds. Apply only if you reviewed and expect these changes."
        alert.addButton(withTitle: "Apply All Changes")
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.applyCommentFix(configConfirmed: true) }
        }
        if let window = documentController?.window { alert.beginSheetModal(for: window, completionHandler: decide) }
        else { decide(alert.runModal()) }
    }
    private func updateButtons() {
        updateBarVisibility()
        let busy = task != nil
        let pending = patch != nil || commentFixPatch != nil
        let applied = patches.applied != nil || commentFixes.applied != nil
        controls.forEach { $0.isEnabled = !busy && !applied }
        analyzeButton.isEnabled = !busy && selectedPair.count == 2 && !applied && !pending
        analyzeButton.isHidden = !analyzeButton.isEnabled
        reviewButton.isHidden = busy || !pending;reviewButton.isEnabled = !busy && pending
        undoButton.isHidden = busy || !applied
        cancelButton.isHidden = !busy && !pending
        swapButton.isHidden = selectedPair.count != 2 || busy || pending || applied
        applyButton.isEnabled = !busy && pending && !applied
        undoButton.isEnabled = !busy && applied
        cancelButton.toolTip = busy
            ? (commentFixFlowActive ? "Cancel \(AgentProvider.current.name) fix" : "Cancel comparison")
            : "Discard proposal"
        cancelButton.setAccessibilityLabel(cancelButton.toolTip)
        statusButton.isHidden = !busy && !pending && !applied && !hasError
        let symbol = busy ? "ellipsis" : (hasError ? "exclamationmark" : (applied ? "checkmark" : "text.bubble"))
        statusButton.image = NSImage(systemSymbolName:symbol,accessibilityDescription:"Comparison status")
        statusButton.toolTip = statusLabel.stringValue
        statusButton.setAccessibilityLabel(statusLabel.stringValue)
        cancelButton.isEnabled = busy || pending
        logButton.isEnabled = artifacts != nil
    }
    private func launch(_ body:@escaping () async throws -> Void) {
        guard task == nil else { return }
        hasError = false
        task = Task {
            defer { self.task = nil; self.selectionUpdated(); self.updateButtons() }
            do { try await body() }
            catch {
                self.hasError = !(error is CancellationError)
                let message = error is CancellationError ? "Cancelled." : error.localizedDescription
                let applied = self.patches.applied != nil || self.commentFixes.applied != nil
                self.statusLabel.stringValue = (applied ? "Applied, not verified. " : "") + message
                self.artifacts?.event("stopped",detail:message)
                if self.commentFixFlowActive { self.reportFixStatus(self.statusLabel.stringValue, error: self.hasError) }
            }
        }
        updateButtons()
    }
    private func invalidate() {
        proposal = nil;patch = nil;reference = nil;before = nil;after = nil;analyzedFrameID = nil
        commentFixProposal = nil;commentFixPatch = nil
        images.forEach { $0.image = nil };output.string = "";updateButtons()
    }
    func refreshFrames() {
        let oldRef = referencePicker.selectedItem?.representedObject as? String
        let oldActual = actualPicker.selectedItem?.representedObject as? String
        referencePicker.removeAllItems();actualPicker.removeAllItems()
        for frame in project?.workspace.frames ?? [] {
            for picker in [referencePicker,actualPicker] {
                picker.addItem(withTitle:"#\(frame.num) \(frame.label)")
                picker.lastItem?.representedObject = frame.id
            }
        }
        select(referencePicker,id:oldRef);select(actualPicker,id:oldActual)
        if oldActual == nil && actualPicker.numberOfItems > 1 { actualPicker.selectItem(at:1) }
    }
    private func select(_ picker:NSPopUpButton,id:String?) {
        if let item = picker.itemArray.first(where:{$0.representedObject as? String == id}) { picker.select(item) }
    }

    @objc private func connectCodex() {
        setupPopover.close()
        documentController?.showSettings()
    }
    @objc private func refreshCodexConnection() {
        let store = CodexConnectionStore.shared
        guard !store.isChecking else { return }
        client = store.makeClient()
        connectionLabel.stringValue = store.status
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.message = "Choose the source folder for the implementation frame."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            workspace = try AstraWorkspace(root:url);ProjectTrust.trust(url);demoRoot = nil;invalidate();folderLabel.stringValue = url.path;updateButtons()
            if project?.setFixSource(url) == false {
                statusLabel.stringValue = "macOS did not allow Web Frames to remember this folder; choose it again after relaunch."
            }
        }
        catch {statusLabel.stringValue = error.localizedDescription}
    }

    /// The folder `workspaceForProject()` would open, without opening it.
    /// `nil` means there is nothing to ask about yet (no source configured).
    private func candidateSourceRoot() -> URL? {
        if let workspace { return workspace.root }
        return project?.resolvedFixSource() ?? project?.resolvedProjectRoot()
    }

    /// The source root may come from the document file itself, so the first
    /// Codex action on this machine asks before any file leaves the folder.
    private func withTrustedSource(_ body: @escaping @MainActor () -> Void) {
        guard let root = candidateSourceRoot(), !ProjectTrust.isTrusted(root) else { body(); return }
        let window = documentController?.canvasHost.window
        ProjectTrust.confirm(root, purpose: .codex, in: window) { [weak self] approved in
            guard let self else { return }
            if approved { body() }
            else { self.statusLabel.stringValue = "\(AgentProvider.current.name) was not given access to \(root.path)." ; self.updateButtons() }
        }
    }

    private func workspaceForProject() throws -> AstraWorkspace {
        if let workspace { return workspace }
        if let root = project?.resolvedFixSource() {
            let opened = try AstraWorkspace(root: root)
            workspace = opened; folderLabel.stringValue = opened.root.path
            return opened
        }
        guard let root = project?.resolvedProjectRoot() else {
            throw AstraError.message("Import a project folder before using Fix with \(AgentProvider.current.name).")
        }
        let opened = try AstraWorkspace(root: root)
        workspace = opened
        demoRoot = nil
        folderLabel.stringValue = opened.root.path
        return opened
    }

    private func reportFixStatus(_ message: String, error: Bool = false) {
        commentFixFlowActive = true
        hasError = error
        statusLabel.stringValue = message
        updateButtons()
        if let host = documentController?.canvasHost { ToastView.show(message: message, in: host) }
        if !bar.isHidden { showStatus() }
    }

    private func chooseFixSourceAndContinue() {
        guard let owner = documentController?.window, owner.attachedSheet == nil, let project else {
            reportFixStatus("Close the current dialog and try Fix with \(AgentProvider.current.name) again.", error: true)
            return
        }
        let candidates = FixProjectDiscovery.suggestions(projectName: project.payload.name,
            directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Develop"))
        func browse() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.title = "Connect project source"
            panel.prompt = "Use Folder"
            panel.message = "Choose the code project for this board. \(AgentProvider.current.name) will use your screenshots and comments to find the screen. Changes require review and Apply."
            panel.directoryURL = candidates.first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Develop")
            panel.beginSheetModal(for: owner) { [weak self] response in
                guard let self else { return }
                guard response == .OK, let url = panel.url else { self.reportFixStatus("Source selection cancelled. Your comments are unchanged."); return }
                self.connectFixSource(url)
            }
        }
        guard !candidates.isEmpty else { browse(); return }
        let alert = NSAlert()
        alert.messageText = "Connect source for “\(project.payload.name)”"
        alert.informativeText = "These folders have similar names. Confirm the source project once; screenshots and comments will help \(AgentProvider.current.name) locate the right screen."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        candidates.forEach { picker.addItem(withTitle: $0.path) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Use Selected Folder")
        alert.addButton(withTitle: "Choose Another Folder…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: owner) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.connectFixSource(candidates[picker.indexOfSelectedItem]) }
            else if response == .alertSecondButtonReturn { browse() }
            else { self.reportFixStatus("Source selection cancelled. Your comments are unchanged.") }
        }
    }

    private func connectFixSource(_ url: URL) {
        do {
            workspace = try AstraWorkspace(root: url)
            project?.setFixSource(url)
            demoRoot = nil; folderLabel.stringValue = url.path
            fixOpenComments()
        } catch { reportFixStatus(error.localizedDescription, error: true) }
    }

    func fixOpenComments() {
        commentFixFlowActive = true
        updateButtons()
        guard task == nil else { reportFixStatus(statusLabel.stringValue); return }
        if commentFixPatch != nil { showReview(); return }
        if commentFixes.applied != nil {
            reportFixStatus("A \(AgentProvider.current.name) fix is already applied. Verify it or Undo before starting another.")
            return
        }
        guard let project else { reportFixStatus("The project is no longer open.", error: true); return }
        let open = project.workspace.annotations.filter { !$0.resolved }
        guard !open.isEmpty else { reportFixStatus("There are no open comments to fix."); return }
        guard open.count <= 30 else { reportFixStatus("Fix with \(AgentProvider.current.name) supports up to 30 open comments at a time.", error: true); return }
        if workspace == nil && project.payload.fixSource == nil && project.workspace.projectMap == nil {
            chooseFixSourceAndContinue()
            return
        }
        refreshCodexConnection()
        guard client != nil else {
            reportFixStatus("Connect \(AgentProvider.current.name) in Settings, then click Fix with \(AgentProvider.current.name) again.", error: true)
            askToConnectAgent(for: "Fix with \(AgentProvider.current.name)")
            return
        }
        withTrustedSource { [weak self] in self?.startCommentFix(open: open) }
    }

    private func startCommentFix(open: [AnnotationModel]) {
        guard task == nil, let project else { return }
        do {
            let workspace = try workspaceForProject()
            let frameIDs = Set(open.map(\.frameId))
            let frames = project.workspace.frames
            let screenshots = try CodexCommentImages.make(frames: frames.filter { frameIDs.contains($0.id) && $0.isImage })
            let context = CodexCommentContextBuilder.make(annotations: open, frames: frames,
                projectName: project.payload.name, frameScreenshots: screenshots)
            invalidate()
            statusLabel.stringValue = "Reading comments and screenshots…"
            launch {
                guard let client = self.client else { throw AstraError.message("Connect \(AgentProvider.current.name) first.") }
                let artifacts = try AstraRunArtifacts();self.artifacts = artifacts
                artifacts.event("comment_fix_started",detail:"comments=\(context.comments.count), images=\(context.images.count)")
                self.statusLabel.stringValue = "\(AgentProvider.current.name) is reading comments, screenshots and project source…"
                let proposal = try await client.fixComments(context.comments, images: context.images,
                    workspace: workspace, artifacts: artifacts) { self.statusLabel.stringValue = $0 }
                try Task.checkCancellation()
                if proposal.files.isEmpty {
                    self.reportFixStatus(proposal.summary.isEmpty ? "\(AgentProvider.current.name) could not map these comments to a safe code change. Check the source folder and describe the screen more precisely." : proposal.summary, error: true)
                    return
                }
                let patch = try self.commentFixes.prepare(proposal, allowedCommentIDs: Set(open.map(\.id)), workspace: workspace)
                self.commentFixProposal = proposal; self.commentFixPatch = patch
                self.output.string = (client.lastSnapshotSummary.map { $0 + "\n\n" } ?? "") + patch.reviewText
                try Data(self.output.string.utf8).write(to: artifacts.url.appendingPathComponent("comment-fix-review.txt"), options: .atomic)
                self.statusLabel.stringValue = "\(AgentProvider.current.name) prepared \(patch.entries.count) file change(s) for review."
                self.showReview()
            }
        } catch { reportFixStatus(error.localizedDescription, error: true) }
    }
    private func selectedFrames() throws -> (String,String,WKWebView,WKWebView) {
        guard let r = referencePicker.selectedItem?.representedObject as? String,
              let a = actualPicker.selectedItem?.representedObject as? String,r != a,
              let rw = documentController?.canvasHost.bridge.astraWebView(id:r),let aw = documentController?.canvasHost.bridge.astraWebView(id:a) else {
            throw AstraError.message("Choose two different, loaded frames.")
        }
        return (r,a,rw,aw)
    }
    @objc private func analyze() {
        guard patches.applied == nil else {return}
        guard client != nil else { askToConnectAgent(for: "Compare"); return }
        withTrustedSource { [weak self] in self?.startAnalysis() }
    }

    /// Compare and Fix need a connected coding agent. Explain that and let the
    /// user decide, instead of throwing the Settings window at them.
    private func askToConnectAgent(for action: String) {
        let provider = AgentProvider.current
        statusLabel.stringValue = "\(action) needs \(provider.productName). Connect it in Settings."
        let alert = NSAlert()
        alert.messageText = "\(action) Needs \(provider.productName)"
        alert.informativeText = "\(action) sends the two frames and your source to \(provider.productName) through its saved sign-in. " + provider.signInHint
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.documentController?.showSettings() }
        }
        if let window = documentController?.window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: open) }
        else { open(alert.runModal()) }
    }

    private func startAnalysis() {
        guard patches.applied == nil, task == nil else { return }
        let activeWorkspace: AstraWorkspace
        do {
            activeWorkspace = try workspaceForProject()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            showSetup()
            return
        }
        invalidate()
        launch {
            guard let client = self.client else {throw AstraError.message("Connect \(AgentProvider.current.name) first.")}
            let (_,id,rw,aw) = try self.selectedFrames()
            let artifacts = try AstraRunArtifacts();self.artifacts = artifacts
            artifacts.event("capture_started");self.statusLabel.stringValue = "Capturing reference and implementation…"
            let reference = try await self.capture.capture(rw)
            let before = try await self.capture.capture(aw)
            guard reference.width == before.width,reference.height == before.height else {throw AstraError.message("Use the same logical width and height for both frames.")}
            try reference.save(to:artifacts.url,name:"reference");try before.save(to:artifacts.url,name:"before")
            self.reference = reference;self.before = before;self.analyzedFrameID = id
            self.images[0].image = reference.image;self.images[1].image = before.image
            self.statusLabel.stringValue = "\(AgentProvider.current.name) is comparing frames and reading code…"
            let proposal = try await client.analyze(reference:reference,actual:before,workspace:activeWorkspace,artifacts:artifacts) {self.statusLabel.stringValue = $0}
            try Task.checkCancellation()
            let patch = try self.patches.prepare(proposal,workspace:activeWorkspace)
            self.proposal = proposal;self.patch = patch
            try await self.publishFindings(proposal,frameID:id,webView:aw,before:before)
            self.output.string = proposal.summary + "\n\n" + proposal.findings.map {"\($0.id) · \($0.selector)\n\($0.mismatch)\nExpected: \($0.expected)"}.joined(separator:"\n\n") + "\n\n" + patch.reviewText
            try Data(patch.reviewText.utf8).write(to:artifacts.url.appendingPathComponent("review.txt"),options:.atomic)
            self.statusLabel.stringValue = "\(proposal.findings.count) comments added to the implementation. Review fix when ready."
        }
    }
    @objc private func apply() {
        guard let patch,let proposal,let workspace,let client,let artifacts,let reference,let before,let id = analyzedFrameID else {return}
        launch {
            guard let webView = self.documentController?.canvasHost.bridge.astraWebView(id:id) else {throw AstraError.message("Implementation frame was closed.")}
            let current = try await self.capture.capture(webView)
            try current.save(to:artifacts.url,name:"pre-apply")
            guard current.matchesPageState(of:before),current.png == before.png else {
                self.patch = nil
                throw AstraError.message("Implementation changed after analysis. Analyze again. Viewport: \(before.width)×\(before.height) → \(current.width)×\(current.height); page generation: \(before.context["documentID"] ?? "unknown") → \(current.context["documentID"] ?? "unknown").")
            }
            try Task.checkCancellation()
            try self.patches.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:artifacts.url)
            artifacts.event("applied",detail:patch.path)
            self.patch = nil;self.statusLabel.stringValue = "Applied. Reloading the implementation…"
            try await self.capture.reload(webView)
            let after = try await self.capture.capture(webView);self.after = after;self.images[2].image = after.image
            try after.save(to:artifacts.url,name:"after")
            guard after.width == before.width,after.height == before.height,
                  after.context["url"] as? String == before.context["url"] as? String else {throw AstraError.message("Viewport or URL changed during verification.")}
            guard try workspace.read(patch.path).hash == patch.afterHash else {throw AstraError.message("Source changed after Apply. Verification is inconclusive.")}
            let report = try await client.verify(reference:reference,before:before,after:after,proposal:proposal,artifacts:artifacts) {self.statusLabel.stringValue = $0}
            var failures:[String] = []
            if self.demoRoot == workspace.root {
                failures = AstraDemoFixture.check(after)
                let clicked = try await webView.evaluateJavaScript("document.getElementById('report-button').click();document.getElementById('report-status').textContent === 'Report is ready'") as? Bool
                if clicked != true {failures.append("CTA interaction failed")}
                try artifacts.save(failures,name:"fixture-check-failures.json")
            } else if (after.context["documentWidth"] as? Int ?? 0) > after.width + 1 {failures.append("Horizontal overflow remains; inspect before accepting")}
            let verified = failures.isEmpty && report.checks.allSatisfy {$0.status == "verified"}
            self.output.string += "\n\nVERIFICATION\n" + report.summary + "\n\n" + report.checks.map {"\($0.id): \($0.status) — \($0.evidence)"}.joined(separator:"\n")
            if !failures.isEmpty {self.output.string += "\n\nChecks requiring attention:\n" + failures.joined(separator:"\n")}
            self.statusLabel.stringValue = verified ? "Verified for this viewport · fresh before/after evidence saved" : "Applied · some checks remain unresolved. Review the evidence or Undo."
            for check in report.checks {
                if let pinID = self.findingPins[check.id],let store = self.project?.workspace,
                   let pin = store.annotations.first(where:{$0.id == pinID}) {
                    store.updateAnnotation(id:pinID,comment:pin.comment + "\n\nVerification: " + check.status + " — " + check.evidence)
                    if verified && check.status == "verified" && !pin.resolved {store.toggleAnnotationResolved(id:pinID)}
                }
            }
            artifacts.event(verified ? "verified" : "partial")
        }
    }
    private func applyCommentFix(configConfirmed: Bool) {
        guard let patch = commentFixPatch,let workspace,let artifacts else {return}
        launch {
            guard let project = self.project else {
                throw AstraError.message("The Web Frames project was closed.")
            }
            let evidenceTargets = CodexCommentFixEvidencePlanner.targets(
                for: patch,
                annotations: project.workspace.annotations,
                frames: project.workspace.frames
            )
            var beforeCaptures: [(CodexCommentFixEvidenceTarget, WKWebView, AstraCapture, String)] = []
            for (index, target) in evidenceTargets.enumerated() {
                guard let webView = self.documentController?.canvasHost.bridge.astraWebView(id: target.frameID) else {
                    continue
                }
                self.statusLabel.stringValue = "Capturing current frame evidence…"
                let before = try await self.capture.snapshot(webView)
                let stem = "comment-fix-frame-\(index + 1)"
                try before.save(to: artifacts.url, name: stem + "-before")
                beforeCaptures.append((target, webView, before, stem))
            }
            try Task.checkCancellation()
            try self.commentFixes.apply(
                patch, approvedID: patch.id, configFilesConfirmed: configConfirmed,
                workspace: workspace, artifacts: artifacts.url
            )
            self.commentFixPatch = nil
            artifacts.event("comment_fix_applied",detail:"files=\(patch.entries.count)")
            self.statusLabel.stringValue = "Applied. Reloading project frames…"
            self.documentController?.canvasHost.reloadProjectWebFrames()

            var evidence: [CommentFixFrameEvidence] = []
            for (target, webView, before, stem) in beforeCaptures {
                self.statusLabel.stringValue = "Capturing refreshed frame evidence…"
                let after = try await self.capture.capture(webView)
                try after.save(to: artifacts.url, name: stem + "-after")
                evidence.append(CommentFixFrameEvidence(
                    frameID: target.frameID,
                    label: target.label,
                    beforeImage: stem + "-before.png",
                    afterImage: stem + "-after.png",
                    pixelsChanged: before.png != after.png
                ))
            }
            try artifacts.save(evidence, name: "comment-fix-verification.json")
            let changed = evidence.filter(\.pixelsChanged).count
            let evidenceSummary = evidence.isEmpty
                ? "No addressed live frame was available for automatic evidence."
                : "Fresh evidence saved for \(evidence.count) addressed frame(s); \(changed) changed visually."
            self.output.string += "\n\nAPPLIED\nProject frames reloaded. \(evidenceSummary) Comments remain open for visual review."
            self.statusLabel.stringValue = "Applied \(patch.entries.count) file change(s). \(evidenceSummary) Review the frames, then resolve the comments."
            artifacts.event("comment_fix_evidence", detail:"frames=\(evidence.count), changed=\(changed)")
        }
    }

    @objc private func undo() {
        if commentFixes.applied != nil {
            undoCommentFix()
            return
        }
        guard let workspace else {return}
        launch {
            try self.patches.undo(workspace:workspace);self.artifacts?.event("undone")
            if let id = self.analyzedFrameID,let webView = self.documentController?.canvasHost.bridge.astraWebView(id:id) {try await self.capture.reload(webView)}
            if let store = self.project?.workspace {
                for id in self.findingPins.values {
                    if let pin = store.annotations.first(where:{$0.id == id}) {
                        if pin.resolved {store.toggleAnnotationResolved(id:id)}
                        store.updateAnnotation(id:id,comment:pin.comment + "\nFix undone; comparison requires a new run.")
                    }
                }
            }
            self.invalidate();self.statusLabel.stringValue = "Original source restored. Compare again when ready."
        }
    }

    private func undoCommentFix() {
        guard let workspace else {return}
        launch {
            try self.commentFixes.undo(workspace:workspace)
            self.artifacts?.event("comment_fix_undone")
            self.documentController?.canvasHost.reloadProjectWebFrames()
            self.commentFixProposal = nil
            self.output.string = ""
            self.commentFixFlowActive = false
            self.statusLabel.stringValue = "Original project source restored."
        }
    }
    @objc private func cancel() {
        if task == nil && (patch != nil || commentFixPatch != nil) {
            let discardedCommentFix = commentFixPatch != nil
            invalidate()
            if discardedCommentFix { commentFixFlowActive = false }
            statusLabel.stringValue = "Proposal discarded. No source files changed."
            artifacts?.event("discarded")
            return
        }
        task?.cancel();if let client {Task {await client.cancel()}}
    }
    @objc private func showEvidence() {if let url = artifacts?.url {NSWorkspace.shared.open(url)}}
    /// Builds the Northstar sample (live implementation + fixed reference)
    /// in this project and selects the pair so Compare is one click away.
    @objc func openSampleProject() {
        setupPopover.close()
        launch {
            guard let project = self.project,let owner = self.documentController else {return}
            self.invalidate();self.server?.stop()
            let previousSamples = project.workspace.frames.filter {$0.id.hasPrefix("astra-demo-") || $0.id.hasPrefix("astra-reference-")}.map(\.id)
            for id in previousSamples {project.workspace.deleteFrame(id:id)}
            self.demoFrameIDs = []
            let root = try AstraDemoFixture.create();let server = AstraDemoServer(root:root);self.server = server
            let url = try await server.start()
            self.workspace = try AstraWorkspace(root:root);self.demoRoot = self.workspace?.root;self.folderLabel.stringValue = "Sample project · \(root.lastPathComponent)"
            let actualID = "astra-demo-" + UUID().uuidString
            let frame = FrameModel(id:actualID,url:url.absoluteString,label:"Northstar · Implementation",x:80,y:140,w:1280,h:800,num:project.workspace.allocateFrameNum(),isImage:false,filePath:nil)
            project.workspace.createFrame(frame);self.demoFrameIDs.append(actualID)
            self.statusLabel.stringValue = "Preparing a fixed reference from the sample project…"
            guard let webView = owner.canvasHost.bridge.astraWebView(id:actualID) else {throw AstraError.message("Sample frame did not open.")}
            let good = try await self.capture.capture(webView)
            let referenceID = "astra-reference-" + UUID().uuidString
            project.workspace.createFrame(FrameModel(id:referenceID,url:"image://Northstar-reference",label:"Northstar · Reference",x:1430,y:140,w:1280,h:800,num:project.workspace.allocateFrameNum(),isImage:true,filePath:nil,extras:["imgUrl":.string(good.dataURL),"natW":.number(1280),"natH":.number(800)]))
            self.demoFrameIDs.append(referenceID)
            try Data(AstraDemoFixture.brokenCSS.utf8).write(to:root.appendingPathComponent("styles.css"),options:.atomic)
            try await self.capture.reload(webView)
            self.refreshFrames();self.select(self.referencePicker,id:referenceID);self.select(self.actualPicker,id:actualID)
            self.images[0].image = good.image
            let bad = try await self.capture.capture(webView);self.images[1].image = bad.image
            project.workspace.setViewport(ViewportModel(scale:0.4,panX:0,panY:0))
            owner.canvasHost.setFrameSelection([referenceID,actualID])
            self.selectedPair = [referenceID,actualID]; self.updatePairLabel(); self.bar.isHidden = false
            self.statusLabel.stringValue = "Sample ready. Compare to add comments to the implementation."
        }
    }
    private func publishFindings(_ proposal:AstraProposal,frameID:String,webView:WKWebView,before:AstraCapture) async throws {
        guard let store = project?.workspace, let frame = store.frames.first(where:{$0.id == frameID}) else {throw AstraError.message("Implementation frame was closed.")}
        // Resolve selectors against the captured document; never evaluate model text as JavaScript.
        var pins:[AnnotationModel] = []
        for (index,finding) in proposal.findings.enumerated() {
            let literal = String(data:try JSONEncoder().encode(finding.selector),encoding:.utf8)!
            let script = "(() => {try {const e=document.querySelector(" + literal + ");if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};}catch{return null;}})()"
            let point = try await webView.evaluateJavaScript(script) as? [String:Double]
            let x = point.map {max(1,min(99,$0["x",default:0]/Double(before.width)*100))} ?? 96
            let y = point.map {max(1,min(99,$0["y",default:0]/Double(before.height)*100))} ?? min(95,12+Double(index)*9)
            let comment = "\(AgentProvider.current.name) · " + finding.mismatch + "\nExpected: " + finding.expected + "\nElement: " + finding.selector + (point == nil ? "\nLocation unavailable; pinned to frame edge." : "")
            pins.append(AnnotationModel(id:"astra-pin-"+UUID().uuidString,num:store.allocateAnnotationNum(),frameId:frameID,xPct:x,yPct:y,color:"orange",comment:comment,resolved:false,edits:[:],frameUrl:frame.url,frameLabel:frame.label,extras:["astraFindingID":.string(finding.id),"initialScrollX":.number(before.context["scrollX"] as? Double ?? 0),"initialScrollY":.number(before.context["scrollY"] as? Double ?? 0)]))
        }
        let current = try await capture.capture(webView)
        guard current.matchesPageState(of:before),current.png == before.png else {patch = nil;throw AstraError.message("Frame changed during comparison. Compare again.")}
        for old in store.annotations where old.frameId == frameID && old.extras["astraFindingID"] != nil {store.deleteAnnotation(id:old.id)}
        findingPins = [:]
        for (finding,pin) in zip(proposal.findings,pins) {store.createAnnotation(pin);findingPins[finding.id] = pin.id}
    }
    func shutdown() {cancel();closeReview();setupPopover.close();statusPopover.close();bar.removeFromSuperview();server?.stop();server = nil}
}
