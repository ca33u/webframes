import AppKit

/// Reproducible, app-scoped preparation. Only test values belong in document data.
nonisolated struct SimulatorTestState: Codable, Hashable, Sendable {
    enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    var name: String
    var account: String = ""
    var data: [String: String] = [:]
    var theme: Theme = .system
    var launchArguments: [String] = []
    var preparation: [SimulatorCaptureRecipe.Step] = []
    var readySelector: String

    func validate() throws {
        guard ![name, account, readySelector].contains(where: { $0.contains("\0") }),
            data.values.allSatisfy({ !$0.contains("\0") }), preparation.allSatisfy({ !$0.value.contains("\0") }),
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            account.utf8.count <= 512, data.count <= 32, launchArguments.count <= 30,
            preparation.count <= 30, !readySelector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            readySelector.utf8.count <= 4096,
            data.allSatisfy({
                $0.key.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil && $0.key.count <= 64
                    && $0.value.utf8.count <= 4096
            }),
            launchArguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
            (try JSONEncoder().encode(data)).count <= 16 * 1024
        else {
            throw SimulatorCapture.failure(
                "Name the test state, choose a ready label / identifier, and use up to 32 test data values and 30 preparation actions."
            )
        }
        for step in preparation {
            guard step.value.utf8.count <= 4096,
                ![.tap, .wait, .type].contains(step.action)
                    || !step.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw SimulatorCapture.failure("Complete each preparation action.")
            }
        }
    }
    func expand(_ text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: "\\{\\{([^{}]+)\\}\\}")
        let original = text as NSString
        var result = ""
        var end = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)) {
            let before = original.substring(with: NSRange(location: end, length: match.range.location - end))
            guard !before.contains("{{") else { throw SimulatorCapture.failure("Unclosed test-state placeholder.") }
            result += before
            let key = original.substring(with: match.range(at: 1))
            if key == "account" {
                result += account
            } else if key.hasPrefix("data."), let value = data[String(key.dropFirst(5))] {
                result += value
            } else {
                throw SimulatorCapture.failure("Unknown test-state placeholder. Use {{account}} or {{data.key}}.")
            }
            end = NSMaxRange(match.range)
        }
        let suffix = original.substring(from: end)
        guard !suffix.contains("{{") else { throw SimulatorCapture.failure("Unclosed test-state placeholder.") }
        result += suffix
        guard result.utf8.count <= 4096 else {
            throw SimulatorCapture.failure("Expanded test-state value exceeds 4 KiB.")
        }
        return result
    }
    var launchEnvironment: [String: String] {
        let bytes = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? Data("{}".utf8)
        return [
            "WEBFRAMES_TEST_STATE": name, "WEBFRAMES_TEST_ACCOUNT": account,
            "WEBFRAMES_TEST_DATA": String(decoding: bytes, as: UTF8.self), "WEBFRAMES_TEST_THEME": theme.rawValue,
        ]
    }
}

extension SimulatorCaptureRecipe {
    func resolvingTestState() throws -> Self {
        try validate()
        guard let state = testState else { return self }
        var result = self
        result.steps = try steps.map { .init(action: $0.action, value: try state.expand($0.value)) }
        result.testState?.preparation = try state.preparation.map {
            .init(action: $0.action, value: try state.expand($0.value))
        }
        result.testState?.readySelector = try state.expand(state.readySelector)
        result.testState?.launchArguments = try state.launchArguments.map { try state.expand($0) }
        try result.validate()
        return result
    }
}

/// Device appearance is temporary and restored on success, failure and cancellation.
@MainActor final class SimulatorAppearanceLease {
    private let service: SimulatorCapture
    private let recipe: SimulatorCaptureRecipe
    private var previous: String?
    private var serial: String?
    init(service: SimulatorCapture, recipe: SimulatorCaptureRecipe) {
        self.service = service
        self.recipe = recipe
    }
    func apply() async throws {
        guard let state = recipe.testState, state.theme != .system else { return }
        if recipe.platform == .iOS {
            let bytes = try await service.command(["simctl", "ui", recipe.deviceID, "appearance"])
            let old = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["light", "dark"].contains(old) else {
                throw SimulatorCapture.failure("Cannot read simulator appearance.")
            }
            previous = old
            _ = try await service.command(["simctl", "ui", recipe.deviceID, "appearance", state.theme.rawValue])
        } else {
            guard let serial = try await service.android.serial(for: recipe.deviceID) else {
                throw SimulatorCapture.failure("Android emulator disconnected.")
            }
            self.serial = serial
            let bytes = try await service.android.shell(serial, ["cmd", "uimode", "night"])
            let old =
                String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).components(
                    separatedBy: ": "
                ).last ?? ""
            guard ["auto", "yes", "no", "custom"].contains(old), old != "custom" else {
                throw SimulatorCapture.failure("Choose a standard emulator night mode before applying a test theme.")
            }
            previous = old
            _ = try await service.android.shell(
                serial, ["cmd", "uimode", "night", state.theme == .dark ? "yes" : "no"])
        }
    }
    func restore() async throws {
        guard let previous else { return }
        try await Task { @MainActor in
            if let serial {
                _ = try await service.android.shell(serial, ["cmd", "uimode", "night", previous])
            } else {
                _ = try await service.command(["simctl", "ui", recipe.deviceID, "appearance", previous])
            }
        }.value
        self.previous = nil
    }
}
