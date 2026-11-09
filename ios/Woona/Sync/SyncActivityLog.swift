import Foundation

/// A bounded journal of actual actions, not a reconstruction of current sync status.
/// Profile IDs refer to immutable VERSION UUIDs; recording IDs are recording UUIDs.
/// Never pass payloads, messages, URLs, headers, tokens or animal names to this API.
struct SyncActivityEvent: Equatable, Codable {
    let timestampUtc: String
    let entityKind: String
    let entityId: String
    let action: String
    let outcome: String
    let code: String?
}

enum SyncActivityAction: String {
    case localSaved = "local_saved"
    case profileValidation = "profile_validation"
    case upload
    case checkDelivery = "check_delivery"
    case restore
    case error
}

enum SyncActivityOutcome: String {
    case started, succeeded, failed, queued
    case waitingNetwork = "waiting_network"
    case waitingServer = "waiting_server"
}

/// Best-effort app-private diagnostics, NOT a durable sync queue or a prerequisite
/// for saving data. record is nonblocking; process termination may lose pending
/// writes. recent reads a small preference value: callers should use a background
/// thread. Preference errors/invalid rows never propagate to persistence or sync.
final class SyncActivityLog: @unchecked Sendable {
    static let shared = SyncActivityLog()
    static let maxEvents = 128
    static let preferenceKey = "woona.syncActivityLog.v1"
    static let maxJSONBytes = 65536
    private static let lock = NSLock()
    // Admission never shares a mutex with preference IO: a stalled writer must
    // not hold up a subsequent local-save callback calling record on main.
    private static let admissionLock = NSLock()
    private static let writer = DispatchQueue(label: "woona.sync-activity-log", qos: .utility)
    private static var pending = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(kind: String, id: String, action: SyncActivityAction,
                outcome: SyncActivityOutcome, code: String? = nil) {
        let event = SyncActivityEvent(timestampUtc: ISO8601DateFormatter().string(from: Date()),
            entityKind: kind, entityId: id, action: action.rawValue,
            outcome: outcome.rawValue, code: Self.safeCode(code))
        guard Self.isSafe(event) else { return }
        Self.admissionLock.lock()
        // Bound pending memory if storage stalls. Drop diagnostics, never block sync.
        guard Self.pending < Self.maxEvents else { Self.admissionLock.unlock(); return }
        Self.pending += 1
        Self.admissionLock.unlock()
        Self.writer.async { [self] in
            Self.lock.lock()
            defer {
                Self.lock.unlock()
                Self.admissionLock.lock()
                Self.pending -= 1
                Self.admissionLock.unlock()
            }
            let events = Self.capped(read() + [event])
            guard let data = try? JSONEncoder().encode(events), data.count <= Self.maxJSONBytes else { return }
            defaults.set(data, forKey: Self.preferenceKey)
        }
    }

    func recent(kind: String, id: String, limit: Int = 20) -> [SyncActivityEvent] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.filterRecent(read(), kind: kind, id: id, limit: limit)
    }

    private func read() -> [SyncActivityEvent] {
        Self.decode(defaults.data(forKey: Self.preferenceKey))
    }

    /// Parse rows independently: one malformed row must not hide other safe events.
    static func decode(_ data: Data?) -> [SyncActivityEvent] {
        guard let data, data.count <= maxJSONBytes,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return capped(rows.compactMap { value in
            guard let row = value as? [String: Any],
                  let time = row["timestampUtc"] as? String,
                  let kind = row["entityKind"] as? String, let id = row["entityId"] as? String,
                  let action = row["action"] as? String, let outcome = row["outcome"] as? String else { return nil }
            let event = SyncActivityEvent(timestampUtc: time, entityKind: kind, entityId: id,
                action: action, outcome: outcome, code: safeCode(row["code"] as? String))
            return isSafe(event) ? event : nil
        })
    }

    // A code is a fixed category, not a truncated/sanitized arbitrary error message.
    static let allowedCodes: Set<String> = [
        "offline", "server_disabled", "wifi_required", "network_error", "timeout", "cancelled",
        "validation_failed", "identity_conflict", "access_denied", "not_found", "integrity_error",
        "local_io", "server_error", "unknown_error", "http_400", "http_401", "http_403",
        "http_404", "http_408", "http_409", "http_413", "http_422", "http_429", "http_500",
        "http_502", "http_503", "http_504", "network_unavailable", "server_not_configured",
        "animal_id_already_exists", "profile_validation_failed", "upload_failed", "questionnaire_update_failed"
    ]
    static func safeCode(_ code: String?) -> String? {
        guard let code, allowedCodes.contains(code) else { return nil }
        return code
    }

    static func isSafe(_ event: SyncActivityEvent) -> Bool {
        guard (20...35).contains(event.timestampUtc.count),
              event.timestampUtc.hasSuffix("Z"),
              SyncActivityAction(rawValue: event.action) != nil,
              SyncActivityOutcome(rawValue: event.outcome) != nil,
              event.code == nil || allowedCodes.contains(event.code!) else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: event.timestampUtc) != nil ||
                ISO8601DateFormatter().date(from: event.timestampUtc) != nil else { return false }
        switch event.entityKind {
        case "profile", "recording":
            return event.entityId.count == 36 && UUID(uuidString: event.entityId) != nil
        case "account":
            return event.entityId.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z", options: .regularExpression) != nil
        default: return false
        }
    }

    static func capped(_ events: [SyncActivityEvent]) -> [SyncActivityEvent] {
        Array(events.filter(isSafe).suffix(maxEvents))
    }

    static func filterRecent(_ events: [SyncActivityEvent], kind: String, id: String,
                             limit: Int = 20) -> [SyncActivityEvent] {
        Array(capped(events).reversed().filter { $0.entityKind == kind && $0.entityId == id }
            .prefix(max(0, min(limit, maxEvents))))
    }
}

/// Pure presentation; unknown values do not leak unvalidated persisted text.
func syncActivityActionLabel(_ value: String, russian: Bool) -> String {
    switch SyncActivityAction(rawValue: value) {
    case .localSaved: return russian ? "Сохранение на телефоне" : "Local save"
    case .profileValidation: return russian ? "Проверка анкеты" : "Profile validation"
    case .upload: return russian ? "Отправка на сервер" : "Upload"
    case .checkDelivery: return russian ? "Проверка доставки" : "Delivery check"
    case .restore: return russian ? "Восстановление" : "Restore"
    case .error: return russian ? "Ошибка" : "Error"
    case nil: return russian ? "Неизвестное действие" : "Unknown action"
    }
}

func syncActivityOutcomeLabel(_ value: String, russian: Bool) -> String {
    switch SyncActivityOutcome(rawValue: value) {
    case .started: return russian ? "Начато" : "Started"
    case .succeeded: return russian ? "Успешно" : "Succeeded"
    case .failed: return russian ? "Не удалось" : "Failed"
    case .waitingNetwork: return russian ? "Ожидает сети" : "Waiting for network"
    case .waitingServer: return russian ? "Ожидает подключения сервера" : "Waiting for server configuration"
    case .queued: return russian ? "В очереди" : "Queued"
    case nil: return russian ? "Неизвестный результат" : "Unknown outcome"
    }
}
