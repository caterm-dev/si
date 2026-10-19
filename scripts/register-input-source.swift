import Carbon
import Foundation

// Only register SI. Never enable/select a source or inspect the user's other input sources.
let arguments = Array(CommandLine.arguments.dropFirst())
let expectedIdentifier = "com.caterm.inputmethod.si"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard arguments.count == 2, ["--register", "--check"].contains(arguments[0]) else {
    fail("Usage: xcrun swift scripts/register-input-source.swift --register|--check <installed SI.app>")
}

let location = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let allowedLocations = [
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Input Methods/SI.app"),
    URL(filePath: "/Library/Input Methods/SI.app"),
]
guard allowedLocations.contains(where: { $0.standardizedFileURL.path == location.path }),
      let bundle = Bundle(url: location), bundle.bundleIdentifier == expectedIdentifier,
      bundle.object(forInfoDictionaryKey: "TISInputSourceID") as? String == expectedIdentifier,
      bundle.object(forInfoDictionaryKey: "TISIntendedLanguage") as? String == "en",
      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true else {
    fail("SI's installed input-method metadata is missing or outdated. Run ./scripts/install.sh to install the corrected bundle.")
}

if arguments[0] == "--register" {
    let status = TISRegisterInputSource(location as CFURL)
    guard status == noErr else {
        fail("SI was copied but registration failed (OSStatus \(status)). The input source has not been enabled. Keep this output for diagnosis.")
    }
}

let filter = [kTISPropertyBundleID as String: expectedIdentifier] as CFDictionary
guard let result = TISCreateInputSourceList(filter, true) else {
    fail("macOS did not return SI registration metadata. Run this command in your normal logged-in Terminal session.")
}
let sources = result.takeRetainedValue() as! [TISInputSource]
let selectable = sources.filter { source in
    guard let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
          let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
          let capability = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
          let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return false }
    let languageList = Unmanaged<CFArray>.fromOpaque(languages).takeUnretainedValue() as NSArray
    return Unmanaged<CFString>.fromOpaque(identifier).takeUnretainedValue() as String == expectedIdentifier
        && Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() == kTISTypeKeyboardInputMethodWithoutModes
        && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(capability).takeUnretainedValue())
        && languageList.firstObject as? String == "en"
}
guard selectable.count == 1 else {
    fail("SI is installed, but macOS reports \(selectable.count) selectable SI keyboard input sources. Registration is not verified; do not treat copying the app as success.")
}
print("Verified: one selectable SI keyboard input source (\(expectedIdentifier)).")
print("Primary discovery language: en (English).")
print("SI has not been enabled or selected by this command.")
