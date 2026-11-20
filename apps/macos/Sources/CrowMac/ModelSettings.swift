import Foundation
import Security

/// Model providers the daemon can call directly. Must match `presets` in apps/daemon/internal/llm.
enum CrowModelProvider: String, CaseIterable {
    case openai, anthropic, deepseek, moonshot, qwen, glm, openrouter, ollama, custom

    var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Moonshot (Kimi)"
        case .qwen: return "Qwen (DashScope)"
        case .glm: return "Zhipu GLM"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Shown as placeholder; empty means the user must fill it in.
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-sonnet-5-5"
        case .deepseek: return "deepseek-chat"
        default: return ""
        }
    }

    static func from(_ raw: String) -> CrowModelProvider {
        CrowModelProvider(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .openai
    }
}

/// API keys live in the Keychain, one per provider, and are handed to the daemon at
/// launch (env) or on save (write-only settings field). They are never written to disk.
enum CrowModelKeychain {
    private static let service = "ai.crow.llm"

    static func apiKey(for provider: CrowModelProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func setAPIKey(_ value: String, for provider: CrowModelProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return
        }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Key for the provider currently configured in runtime settings, for daemon launch.
    static func configuredAPIKey() -> String? {
        apiKey(for: .from(CrowEnvironment.value("CROW_LLM_PROVIDER") ?? ""))
    }
}
