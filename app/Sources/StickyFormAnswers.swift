import Foundation

/// Persists only the answers a team's form explicitly marks as sticky.
///
/// A single namespaced payload is intentional. Importing another team's
/// configuration must never surface the previous team's shoot details, while
/// quitting or crashing during a multi-card job should not force an operator
/// to reconstruct the brief before a safe resume.
enum StickyFormAnswers {
    private static let defaultsKey = "sticky-form-answers-v1"

    private struct Payload: Codable {
        let namespace: String
        let answers: [String: String]
    }

    private struct Fingerprint: Codable {
        let teamName: String
        let fields: [IngestFormField]
    }

    static func load(config: IngestConfig,
                     defaults: UserDefaults = .standard) -> [UUID: String] {
        guard let data = defaults.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.namespace == namespace(for: config) else { return [:] }

        var restored: [UUID: String] = [:]
        for field in config.form.fields where field.sticky && field.automaticValue == nil {
            guard let answer = payload.answers[field.id.uuidString],
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.isValid(answer: answer) else { continue }
            restored[field.id] = answer
        }
        return restored
    }

    static func save(_ answers: [UUID: String], config: IngestConfig,
                     defaults: UserDefaults = .standard) {
        var kept: [String: String] = [:]
        for field in config.form.fields where field.sticky && field.automaticValue == nil {
            guard let answer = answers[field.id],
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.isValid(answer: answer) else { continue }
            kept[field.id.uuidString] = answer
        }
        let payload = Payload(namespace: namespace(for: config), answers: kept)
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func namespace(for config: IngestConfig) -> String {
        let fingerprint = Fingerprint(
            teamName: config.effectiveTeam.teamName,
            fields: config.form.fields)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(fingerprint)) ?? Data()

        // Stable FNV-1a is sufficient for a local namespace and avoids adding
        // an unrelated network or cryptography dependency to the app.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
