import AppKit
import Network
import os
import UniformTypeIdentifiers

// MARK: - GitHubTabPanel

final class GitHubTabPanel: NSView, AddFrameTabPanel {

    var view: NSView { self }

    private let repoField = NSTextField()
    private let fetchBtn = NSButton(title: "Load", target: nil, action: nil)
    private let repoError = NSTextField(labelWithString: "")

    private let onOpenSettings: () -> Void

    private let branchChip = NSTextField(labelWithString: "")
    private let selCountLabel = NSTextField(labelWithString: "0 selected")
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let treeWrap = NSView()

    private lazy var sizeRow = SizeControlRow(onChange: onValidityChange)

    private var owner = ""
    private var repo = ""
    private var branch = "main"
    private var files: [String] = []
    private var selected: Set<String> = []
    private var token: String = ""

    private let onValidityChange: () -> Void

    init(onValidityChange: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onValidityChange = onValidityChange
        super.init(frame: .zero)
        build()
        loadTokenFromKeychain()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        repoField.placeholderString = "https://github.com/user/repo"
        repoField.font = .systemFont(ofSize: 13)
        repoField.delegate = self
        repoField.target = self
        repoField.action = #selector(fetchRepo)
        repoField.translatesAutoresizingMaskIntoConstraints = false
        fetchBtn.target = self
        fetchBtn.action = #selector(fetchRepo)
        fetchBtn.bezelStyle = .rounded
        fetchBtn.translatesAutoresizingMaskIntoConstraints = false

        let repoRow = NSStackView(views: [repoField, fetchBtn])
        repoRow.orientation = .horizontal
        repoRow.alignment = .centerY
        repoRow.spacing = 6
        repoRow.translatesAutoresizingMaskIntoConstraints = false

        repoError.font = .systemFont(ofSize: 11)
        repoError.textColor = .systemRed
        repoError.isHidden = true
        repoError.translatesAutoresizingMaskIntoConstraints = false

        let tokenHint = NSTextField(wrappingLabelWithString: "Private repositories use the GitHub token saved in Settings.")
        tokenHint.font = .systemFont(ofSize: 11); tokenHint.textColor = WFDesign.text2
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "GitHub settings")!, target: self, action: #selector(openSettings))
        settingsButton.toolTip = "GitHub settings"
        settingsButton.bezelStyle = .rounded

        // Tree wrap.
        branchChip.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchChip.textColor = WFDesign.text2
        branchChip.translatesAutoresizingMaskIntoConstraints = false
        selCountLabel.font = .systemFont(ofSize: 10)
        selCountLabel.textColor = WFDesign.text2
        selCountLabel.translatesAutoresizingMaskIntoConstraints = false
        let treeHeader = NSStackView(views: [makeFieldLabel("Pages"), branchChip, {
            let s = NSView(); s.setContentHuggingPriority(.defaultLow, for: .horizontal); return s
        }(), selCountLabel])
        treeHeader.orientation = .horizontal
        treeHeader.alignment = .centerY
        treeHeader.spacing = 8
        treeHeader.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 1
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .lineBorder
        listScroll.documentView = listStack

        let treeVert = NSStackView(views: [treeHeader, listScroll])
        treeVert.orientation = .vertical
        treeVert.alignment = .leading
        treeVert.spacing = 6
        treeVert.translatesAutoresizingMaskIntoConstraints = false
        treeWrap.translatesAutoresizingMaskIntoConstraints = false
        treeWrap.isHidden = true
        treeWrap.addSubview(treeVert)
        NSLayoutConstraint.activate([
            treeVert.topAnchor.constraint(equalTo: treeWrap.topAnchor),
            treeVert.bottomAnchor.constraint(equalTo: treeWrap.bottomAnchor),
            treeVert.leadingAnchor.constraint(equalTo: treeWrap.leadingAnchor),
            treeVert.trailingAnchor.constraint(equalTo: treeWrap.trailingAnchor),
            treeHeader.leadingAnchor.constraint(equalTo: treeVert.leadingAnchor),
            treeHeader.trailingAnchor.constraint(equalTo: treeVert.trailingAnchor),
            listScroll.leadingAnchor.constraint(equalTo: treeVert.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: treeVert.trailingAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: 170),
            listStack.widthAnchor.constraint(equalTo: listScroll.widthAnchor),
        ])

        let root = NSStackView(views: [
            makeFieldLabel("Repository URL"),
            repoRow,
            repoError,
            NSStackView(views: [tokenHint, settingsButton]),
            treeWrap,
            sizeRow,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            repoRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            repoRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            treeWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            treeWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            sizeRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            sizeRow.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: Token

    private func loadTokenFromKeychain() {
        token = (try? KeychainHelper.load(key: "gh_token").get()) ?? ""
    }
    @objc private func openSettings() { onOpenSettings() }

    // MARK: Fetch

    @objc private func fetchRepo() {
        loadTokenFromKeychain()
        let raw = repoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match github.com/owner/repo out of various paste formats
        // (with protocol, with .git, bare slug). Regex matches what the HTML
        // version used.
        let rx = try? NSRegularExpression(pattern: #"github\.com/([^/]+)/([^/?\s#]+)"#)
        guard let rx,
              let match = rx.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let ownerRange = Range(match.range(at: 1), in: raw),
              let repoRange = Range(match.range(at: 2), in: raw) else {
            showRepoError("invalid github url")
            return
        }
        owner = String(raw[ownerRange])
        repo  = String(raw[repoRange]).replacingOccurrences(of: #"\.git$"#, with: "",
                                                           options: .regularExpression)
        hideRepoError()
        fetchBtn.title = "…"
        fetchBtn.isEnabled = false
        treeWrap.isHidden = true

        let currentToken = token
        let ownerCopy = owner
        let repoCopy = repo

        Task { [weak self] in
            do {
                let branch = try await GitHubAPI.fetchDefaultBranch(owner: ownerCopy, repo: repoCopy, token: currentToken)
                let files  = try await GitHubAPI.fetchHtmlFiles(owner: ownerCopy, repo: repoCopy, branch: branch, token: currentToken)
                await MainActor.run {
                    guard let self else { return }
                    self.branch = branch
                    self.files = files
                    self.selected = Set(files.prefix(10))
                    self.branchChip.stringValue = branch
                    self.rebuildList()
                    self.updateCount()
                    self.treeWrap.isHidden = false
                    self.fetchBtn.title = "Load"
                    self.fetchBtn.isEnabled = true
                    self.onValidityChange()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.showRepoError(error.localizedDescription)
                    self.fetchBtn.title = "Load"
                    self.fetchBtn.isEnabled = true
                }
            }
        }
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for path in files {
            let row = FileRow(path: path,
                              initiallySelected: selected.contains(path)) { [weak self] p, on in
                guard let self else { return }
                if on { self.selected.insert(p) } else { self.selected.remove(p) }
                self.updateCount()
                self.onValidityChange()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
        }
    }

    private func updateCount() {
        selCountLabel.stringValue = "\(selected.count) selected"
    }

    private func showRepoError(_ msg: String) {
        repoError.stringValue = msg
        repoError.isHidden = false
    }
    private func hideRepoError() { repoError.isHidden = true }

    // MARK: Spec

    func currentSpec() -> [String: Any]? {
        guard !owner.isEmpty, !repo.isEmpty, !selected.isEmpty else { return nil }
        var spec: [String: Any] = [
            "kind":   "github",
            "owner":  owner,
            "repo":   repo,
            "branch": branch,
            "files":  Array(selected),
            "w":      sizeRow.width,
            "h":      sizeRow.height,
        ]
        if !token.isEmpty { spec["authenticated"] = true }
        return spec
    }

    func reset() {
        loadTokenFromKeychain()
        repoField.stringValue = ""
        repoError.isHidden = true
        owner = ""; repo = ""; branch = "main"
        files = []; selected.removeAll()
        treeWrap.isHidden = true
        sizeRow.applyPreset(index: 1)
    }

}

extension GitHubTabPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Typing in repoField invalidates any previous selection until
        // `load` is pressed again.
        if (obj.object as? NSTextField) === repoField {
            selected.removeAll()
            onValidityChange()
        }
    }
}
