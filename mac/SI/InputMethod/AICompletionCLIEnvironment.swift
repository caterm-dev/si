import CFNetwork
import Foundation

enum AICompletionCLIEnvironment {
    /// Values may contain proxy credentials. Keep them in the child environment only.
    static func make(provider: AICompletionProvider, executable: String, inherited: [String: String],
                     systemProxy: [String: Any] = [:]) -> [String: String] {
        let authentication = provider == .codex ? ["CODEX_HOME", "OPENAI_API_KEY"]
            : ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        let network = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                       "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE",
                       "NODE_EXTRA_CA_CERTS", "NODE_USE_SYSTEM_CA", "NODE_USE_ENV_PROXY"]
        let allowed = Set(["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"] + authentication + network)
        var environment = inherited.filter { allowed.contains($0.key) }
        let directories = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = ([URL(fileURLWithPath: executable).deletingLastPathComponent().path] + directories)
            .joined(separator: ":")

        func proxyURL(enabled: CFString, host: CFString, port: CFString, scheme: String) -> String? {
            guard (systemProxy[enabled as String] as? NSNumber)?.boolValue == true,
                  let hostname = systemProxy[host as String] as? String, !hostname.isEmpty,
                  let number = systemProxy[port as String] as? Int, (1...65535).contains(number) else { return nil }
            var components = URLComponents()
            components.scheme = scheme
            components.host = hostname
            components.port = number
            return components.url?.absoluteString
        }
        let hasExplicitAllProxy = environment["ALL_PROXY"] != nil || environment["all_proxy"] != nil
        var addedSystemProxy = false
        func add(_ name: String, value: String?) {
            guard !hasExplicitAllProxy, environment[name] == nil, environment[name.lowercased()] == nil,
                  let value else { return }
            environment[name] = value
            environment[name.lowercased()] = value
            addedSystemProxy = true
        }
        add("HTTP_PROXY", value: proxyURL(enabled: kCFNetworkProxiesHTTPEnable, host: kCFNetworkProxiesHTTPProxy,
                                         port: kCFNetworkProxiesHTTPPort, scheme: "http"))
        add("HTTPS_PROXY", value: proxyURL(enabled: kCFNetworkProxiesHTTPSEnable, host: kCFNetworkProxiesHTTPSProxy,
                                          port: kCFNetworkProxiesHTTPSPort, scheme: "http"))
        add("ALL_PROXY", value: proxyURL(enabled: kCFNetworkProxiesSOCKSEnable, host: kCFNetworkProxiesSOCKSProxy,
                                        port: kCFNetworkProxiesSOCKSPort, scheme: "socks5"))
        if addedSystemProxy, environment["NO_PROXY"] == nil, environment["no_proxy"] == nil,
           let exceptions = systemProxy[kCFNetworkProxiesExceptionsList as String] as? [String], !exceptions.isEmpty {
            environment["NO_PROXY"] = exceptions.joined(separator: ",")
            environment["no_proxy"] = environment["NO_PROXY"]
        }
        return environment
    }

    static func systemProxySettings() -> [String: Any] {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}
