import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import SILocalization
#endif

struct AICompletionScreenshot: Sendable {
    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let level: Int
    }

    let window: Window
    let png: Data

    enum Failure: Error {
        case permissionRequired, windowChanged, encoding
        case windowNotFound(Int)
        case windowNotShareable
        case captureFailed(domain: String, code: Int)

        var message: String {
            switch self {
            case .permissionRequired: L10n.text("Allow SI in macOS Screen Recording settings to use AI completion.")
            case .windowNotFound(let level):
                L10n.format("No visible window was found for the input app (IMK level %ld).", level)
            case .windowNotShareable:
                L10n.text("The input window is visible but macOS did not list it as capturable.")
            case .captureFailed(let domain, let code):
                L10n.format("Window capture failed (%@, error %ld).", domain, code)
            case .windowChanged: L10n.text("The input window changed. Press Tab to request a new prediction.")
            case .encoding: L10n.text("The window screenshot could not be prepared for AI completion.")
            }
        }
    }

    static func frontWindow(pid: pid_t, level: Int = 0) -> Window? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return selectWindow(records: records, pid: pid, level: level)
    }

    static func selectWindow(records: [[String: Any]], pid: pid_t, level: Int = 0) -> Window? {
        var visible: [Window] = []
        for record in records {
            guard record[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  (record[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let actualLevel = record[kCGWindowLayer as String] as? Int,
                  let number = record[kCGWindowNumber as String] as? UInt32,
                  let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else { continue }
            visible.append(Window(id: number, pid: pid, bounds: bounds, level: actualLevel))
        }
        // IMK's level is a candidate-placement hint, not a window identifier.
        // Some hosts report a level absent from their Window Server records.
        return visible.first(where: { $0.level == level })
            ?? visible.first(where: { $0.level == 0 }) ?? visible.first
    }

    @concurrent
    static func capture(window: Window) async throws -> Self {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw Failure.permissionRequired }
        guard frontWindow(pid: window.pid, level: window.level) == window else { throw Failure.windowChanged }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let target = content.windows.first(where: { $0.windowID == window.id && $0.owningApplication?.processID == window.pid })
            else { throw Failure.windowNotShareable }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = min(2, 1600 / max(window.bounds.width, window.bounds.height))
            configuration.width = max(1, Int(window.bounds.width * scale))
            configuration.height = max(1, Int(window.bounds.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            guard CGPreflightScreenCaptureAccess(), frontWindow(pid: window.pid, level: window.level) == window else { throw Failure.windowChanged }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure.encoding
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), data.length <= 8 * 1024 * 1024 else { throw Failure.encoding }
            return Self(window: window, png: data as Data)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard CGPreflightScreenCaptureAccess() else { throw Failure.permissionRequired }
            let failure = error as NSError
            throw Failure.captureFailed(domain: failure.domain, code: failure.code)
        }
    }
}
