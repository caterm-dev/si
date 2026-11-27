import AppKit
import ApplicationServices
import Carbon

/// Explicit, local inspection from the input menu; never used by typing or AI completion.
@MainActor
final class AXDataExport {
    static let shared = AXDataExport()
    private var task: Task<Void, Never>?
    var isExporting: Bool { task != nil }

    func exportCurrentApplication() {
        guard task == nil else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            showFailure(L10n.text("No foreground application is available for AX export."))
            return
        }
        let target = AXExportTarget(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                    name: app.localizedName, launchDate: app.launchDate)
        task = Task {
            defer { task = nil }
            do {
                let url = try await AXExportWorker(target: target).export()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch let failure as AXExportFailure {
                showFailure(L10n.text(failure.rawValue))
            } catch {
                // File-system errors are shown locally, never logged with captured content.
                showFailure(error.localizedDescription)
            }
        }
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text("AX Export Failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct AXExportTarget: Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String?
    let launchDate: Date?

    @MainActor
    func validate() throws {
        guard AXIsProcessTrusted() else { throw AXExportFailure.permission }
        guard !IsSecureEventInputEnabled() else { throw AXExportFailure.secureInput }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == pid, app.bundleIdentifier == bundleIdentifier,
              app.launchDate == launchDate, !app.isTerminated else { throw AXExportFailure.applicationChanged }
    }
}

private enum AXExportFailure: String, Error {
    case permission = "Allow SI in macOS Accessibility settings before exporting AX data."
    case secureInput = "AX export is unavailable during secure input."
    case applicationChanged = "The foreground application changed. Return to the app and export again."
    case unavailable = "The application did not expose a readable AX tree."
    case tooLarge = "The AX export exceeded the file size limit. No file was saved."
}

/// AX objects and untyped attribute values stay confined to this worker actor.
private actor AXExportWorker {
    private let target: AXExportTarget
    private let maximumNodes = 5_000
    private let maximumArrayValues = 1_024
    private let maximumStringBytes = 262_144
    private var remainingTextBytes = 8 * 1_024 * 1_024
    private var remainingValues = 100_000
    private let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    private var elements: [AXUIElement] = []
    private var identifiers: [CFHashCode: [Int]] = [:]
    private var truncations: Set<String> = []

    init(target: AXExportTarget) { self.target = target }

    func export() async throws -> URL {
        try await target.validate()
        let root = AXUIElementCreateApplication(target.pid)
        _ = reference(root)
        try validateFocus(root)
        var nodes: [[String: Any]] = []
        while nodes.count < elements.count {
            try Task.checkCancellation()
            try await target.validate()
            try validateFocus(root)
            guard hasTime else { break }
            guard remainingValues > 0 else {
                truncations.insert("valueLimit")
                break
            }
            let index = nodes.count
            let node = read(elements[index], id: index)
            if index == 0, node["attributeNamesError"] != nil { throw AXExportFailure.unavailable }
            nodes.append(node)
        }
        let document: [String: Any] = [
            "format": "SI-AX-Export", "version": 1,
            "capturedAt": Date.now.formatted(.iso8601),
            "application": ["pid": Int(target.pid), "bundleIdentifier": target.bundleIdentifier ?? "",
                            "name": target.name ?? ""],
            "root": 0, "nodes": nodes, "discoveredNodeCount": elements.count,
            "truncations": truncations.sorted(),
            "limits": ["nodes": maximumNodes, "arrayValues": maximumArrayValues,
                       "stringUTF8Bytes": maximumStringBytes, "totalTextUTF8Bytes": 8 * 1_024 * 1_024,
                       "attributeAndValueCount": 100_000, "seconds": 20],
            "notes": ["Only attributes exposed by this application are available.",
                      "Secure text elements are redacted. Parameterized attributes are listed, not invoked.",
                      "References use node IDs; cross-process references are not traversed.",
                      "This is a live traversal, not an atomic application snapshot."]
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 32 * 1_024 * 1_024 else { throw AXExportFailure.tooLarge }
        try await target.validate()
        try validateFocus(root)
        let directory = URL.applicationSupportDirectory.appending(path: "SI/AXExports", directoryHint: .isDirectory)
        let timestamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "SI-AX-\(timestamp)-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Create with owner-only permissions before writing any captured bytes.
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            try file.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private var hasTime: Bool {
        guard ContinuousClock.now < deadline else {
            truncations.insert("timeLimit")
            return false
        }
        return true
    }

    private func validateFocus(_ root: AXUIElement) throws {
        guard !IsSecureEventInputEnabled() else { throw AXExportFailure.secureInput }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            _ = AXUIElementSetMessagingTimeout(element, 0.2)
            if isSecure(element) { throw AXExportFailure.secureInput }
        }
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
            && value as? String == kAXSecureTextFieldSubrole as String
    }

    private func reference(_ element: AXUIElement) -> [String: Any] {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)
        guard error == .success else { return ["axError": error.rawValue] }
        guard pid == target.pid else { return ["externalProcess": Int(pid)] }
        let hash = CFHash(element)
        if let id = identifiers[hash]?.first(where: { CFEqual(elements[$0], element) }) { return ["ref": id] }
        guard elements.count < maximumNodes else {
            truncations.insert("nodeLimit")
            return ["omitted": "nodeLimit"]
        }
        let id = elements.count
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
        elements.append(element)
        identifiers[hash, default: []].append(id)
        return ["ref": id]
    }

    private func read(_ element: AXUIElement, id: Int) -> [String: Any] {
        if isSecure(element) { return ["id": id, "redacted": "secureTextElement"] }
        var node: [String: Any] = ["id": id]
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)
        guard error == .success, let attributes = names as? [String] else {
            node["attributeNamesError"] = error.rawValue
            return node
        }
        var values: [String: Any] = [:]
        for name in attributes.sorted().prefix(256) {
            guard hasTime else { break }
            if IsSecureEventInputEnabled() { break }
            guard remainingValues > 0 else {
                truncations.insert("valueLimit")
                break
            }
            remainingValues -= 1
            var value: CFTypeRef?
            var count: CFIndex = 0
            // Page large collections rather than requesting an unbounded child array.
            if AXUIElementGetAttributeValueCount(element, name as CFString, &count) == .success {
                var array: CFArray?
                let result = count == 0 ? AXError.success : AXUIElementCopyAttributeValues(
                    element, name as CFString, 0, min(count, maximumArrayValues), &array)
                if result != .success { values[name] = ["axError": result.rawValue] }
                else {
                    let items = (array as? [Any] ?? []).map { encode($0, depth: 0) }
                    values[name] = ["values": items, "totalCount": count]
                    if count > maximumArrayValues { truncations.insert("arrayLimit") }
                }
            } else {
                let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                values[name] = result == .success ? value.map { encode($0, depth: 0) } ?? NSNull()
                    : ["axError": result.rawValue]
            }
        }
        if attributes.count > 256 { truncations.insert("attributeLimit") }
        node["attributes"] = values
        var parameters: CFArray?
        let parameterError = AXUIElementCopyParameterizedAttributeNames(element, &parameters)
        if parameterError == .success { node["parameterizedAttributeNames"] = boundedNames(parameters) }
        else { node["parameterizedAttributeNamesError"] = parameterError.rawValue }
        var actions: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &actions)
        if actionError == .success { node["actionNames"] = boundedNames(actions) }
        else { node["actionNamesError"] = actionError.rawValue }
        return node
    }

    private func encode(_ value: Any, depth: Int) -> Any {
        guard remainingValues > 0 else {
            truncations.insert("valueLimit")
            return ["omitted": "valueLimit"]
        }
        remainingValues -= 1
        guard depth < 16 else {
            truncations.insert("valueDepthLimit")
            return ["omitted": "valueDepthLimit"]
        }
        let cfValue = value as CFTypeRef
        let type = CFGetTypeID(cfValue)
        if type == AXUIElementGetTypeID() { return reference(cfValue as! AXUIElement) }
        if value is NSNull { return NSNull() }
        if let text = value as? String { return encodeText(text) }
        if let text = value as? NSAttributedString { return ["text": encodeText(text.string), "type": "attributedString"] }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number : ["omitted": "nonFiniteNumber"]
        }
        if let url = value as? URL { return ["url": encodeText(url.absoluteString)] }
        if let array = value as? [Any] {
            if array.count > maximumArrayValues { truncations.insert("arrayLimit") }
            return array.prefix(maximumArrayValues).map { encode($0, depth: depth + 1) }
        }
        if let dictionary = value as? [String: Any] {
            if dictionary.count > maximumArrayValues { truncations.insert("dictionaryLimit") }
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(maximumArrayValues) {
                result[key] = encode(dictionary[key]!, depth: depth + 1)
            }
            return result
        }
        if type == AXValueGetTypeID() { return encodeAXValue(cfValue as! AXValue) }
        // Opaque text markers and other unsupported values cannot be reconstructed as text.
        return ["unsupportedType": CFCopyTypeIDDescription(type) as String? ?? "unknown"]
    }

    private func boundedNames(_ array: CFArray?) -> [String] {
        let names = array as? [String] ?? []
        if names.count > 256 { truncations.insert("nameLimit") }
        return Array(names.prefix(256))
    }

    private func encodeText(_ text: String) -> Any {
        let count = text.utf8.count
        let limit = min(maximumStringBytes, remainingTextBytes)
        if count <= limit {
            remainingTextBytes -= count
            return text
        }
        truncations.insert("textLimit")
        var bytes = Array(text.utf8.prefix(limit))
        // Trim an incomplete trailing scalar while preserving all retained source bytes.
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        remainingTextBytes -= bytes.count
        return ["text": String(decoding: bytes, as: UTF8.self), "originalUTF8Bytes": count, "truncated": true]
    }

    private func encodeAXValue(_ value: AXValue) -> Any {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            if AXValueGetValue(value, .cgPoint, &point) { return encode(["x": point.x, "y": point.y], depth: 0) }
        case .cgSize:
            var size = CGSize.zero
            if AXValueGetValue(value, .cgSize, &size) { return encode(["width": size.width, "height": size.height], depth: 0) }
        case .cgRect:
            var rect = CGRect.zero
            if AXValueGetValue(value, .cgRect, &rect) {
                return encode(["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height], depth: 0)
            }
        case .cfRange:
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(value, .cfRange, &range) { return ["location": range.location, "length": range.length] }
        case .axError:
            var error = AXError.success
            if AXValueGetValue(value, .axError, &error) { return ["axError": error.rawValue] }
        default: break
        }
        return ["unsupportedType": "AXValue"]
    }
}
