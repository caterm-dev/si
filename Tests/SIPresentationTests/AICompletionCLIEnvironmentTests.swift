import CFNetwork
import Foundation
import Testing
@testable import SIPresentation

struct AICompletionCLIEnvironmentTests {
    @Test(arguments: [AICompletionProvider.codex, .claude])
    func preservesProxyCredentialsBypassRulesAndCertificateConfiguration(provider: AICompletionProvider) {
        let values = [
            "HTTP_PROXY": "http://test-user:test-password@127.0.0.1:8080",
            "https_proxy": "http://127.0.0.1:8081",
            "ALL_PROXY": "socks5h://127.0.0.1:1080",
            "NO_PROXY": "localhost,127.0.0.1,.example.test",
            "SSL_CERT_FILE": "/synthetic/cert.pem", "SSL_CERT_DIR": "/synthetic/certs",
            "CURL_CA_BUNDLE": "/synthetic/curl.pem", "REQUESTS_CA_BUNDLE": "/synthetic/requests.pem",
            "NODE_EXTRA_CA_CERTS": "/synthetic/node.pem", "NODE_USE_SYSTEM_CA": "1", "NODE_USE_ENV_PROXY": "1"
        ]
        var inherited = values
        inherited["UNRELATED_SECRET"] = "must-stay-out"
        inherited["ANTHROPIC_API_KEY"] = "test-anthropic"
        inherited["OPENAI_API_KEY"] = "test-openai"
        let result = AICompletionCLIEnvironment.make(provider: provider, executable: "/synthetic/node/bin/codex", inherited: inherited)
        for (key, value) in values { #expect(result[key] == value) }
        #expect(result["UNRELATED_SECRET"] == nil)
        #expect(result[provider == .codex ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"] == nil)
        #expect(result["PATH"]?.hasPrefix("/synthetic/node/bin:") == true)
    }

    @Test func guiProcessUsesStaticSystemProxiesWithoutOverridingExplicitValues() {
        let system: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: 8080,
            kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: 8443,
            kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: 1080,
            kCFNetworkProxiesExceptionsList as String: ["localhost", "*.local"]
        ]
        let fallback = AICompletionCLIEnvironment.make(provider: .codex, executable: "/synthetic/codex", inherited: [:], systemProxy: system)
        #expect(fallback["HTTP_PROXY"] == "http://127.0.0.1:8080")
        #expect(fallback["https_proxy"] == "http://127.0.0.1:8443")
        #expect(fallback["ALL_PROXY"] == "socks5://127.0.0.1:1080")
        #expect(fallback["no_proxy"] == "localhost,*.local")
        let explicit = AICompletionCLIEnvironment.make(provider: .claude, executable: "/synthetic/claude",
            inherited: ["https_proxy": "", "NO_PROXY": "synthetic.test"], systemProxy: system)
        #expect(explicit["https_proxy"] == "")
        #expect(explicit["HTTPS_PROXY"] == nil)
        #expect(explicit["NO_PROXY"] == "synthetic.test")
        #expect(explicit["no_proxy"] == nil)
        let all = AICompletionCLIEnvironment.make(provider: .codex, executable: "/synthetic/codex",
            inherited: ["all_proxy": "http://127.0.0.1:9000"], systemProxy: system)
        #expect(all["all_proxy"] == "http://127.0.0.1:9000")
        #expect(all["HTTP_PROXY"] == nil)
        #expect(all["HTTPS_PROXY"] == nil)
    }
}
