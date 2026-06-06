import Foundation

/// The minimal set of transport commands a Live Activity control can issue against
/// a remote Music Assistant player.
enum MARemoteCommand {
    case togglePlayPause
    case next
    case previous

    /// MA WebSocket command + args for the given queue/player id. In this app the
    /// queue id equals the player id (mirrors `XonoraClient`).
    func payload(queueId: String, messageId: String) -> [String: Any] {
        let command: String
        switch self {
        case .togglePlayPause: command = "player_queues/play_pause"
        case .next: command = "player_queues/next"
        case .previous: command = "player_queues/previous"
        }
        return ["message_id": messageId, "command": command, "args": ["queue_id": queueId]]
    }
}

/// Fire-and-mostly-forget WebSocket client that mirrors `XonoraClient`'s handshake
/// just enough to deliver a single player command, then closes.
///
/// Lives in the shared layer so the widget extension's App Intents can drive the
/// remote speaker **while the app is suspended**, without importing the app target.
/// Connection details are read from the App Group defaults (mirrored there by the
/// app). This is deliberately self-contained — it does not touch `XonoraClient`.
enum MARemoteControl {
    enum ControlError: Error { case noServer, badURL, timeout }

    /// Opens a short-lived connection to MA, authenticates if the server requires it,
    /// sends a single command for `playerId`, then tears down. Throws on
    /// connection/timeout failure.
    static func send(_ command: MARemoteCommand, playerId: String) async throws {
        let defaults = XonoraShared.defaults ?? .standard
        guard let serverURLString = defaults.string(forKey: XonoraShared.DefaultsKey.serverURL),
              let serverURL = URL(string: serverURLString) else {
            throw ControlError.noServer
        }
        let token = defaults.string(forKey: XonoraShared.DefaultsKey.accessToken)

        guard var ws = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { throw ControlError.badURL }
        ws.scheme = serverURL.scheme == "https" ? "wss" : "ws"
        ws.path = "/ws"
        guard let wsURL = ws.url else { throw ControlError.badURL }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: wsURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // 1. Read frames until we learn the schema version (server_info). MA sends it
        //    on connect; loop a few times in case an unrelated frame arrives first.
        var schema = 0
        for _ in 0..<5 {
            let msg = try await receiveJSON(task)
            if let serverVersion = msg["server_version"], serverVersion is String {
                schema = msg["schema_version"] as? Int ?? 0
                break
            }
        }

        // 2. Authenticate when the server demands it (schema >= 28 + a token on hand).
        if schema >= 28, let token, !token.isEmpty {
            try await sendJSON(task, ["message_id": "auth-handshake", "command": "auth", "args": ["token": token]])
            for _ in 0..<5 {
                let msg = try await receiveJSON(task)
                if let result = msg["result"] as? [String: Any], result["authenticated"] as? Bool == true { break }
                if msg["error_code"] != nil { throw ControlError.timeout }
            }
        }

        // 3. Send the actual command.
        let messageId = UUID().uuidString
        try await sendJSON(task, command.payload(queueId: playerId, messageId: messageId))

        // 4. Best-effort: wait for the matching ack so the immediate close doesn't cut
        //    the command off. Ignore unrelated event frames.
        for _ in 0..<8 {
            guard let msg = try? await receiveJSON(task, timeout: 2.0) else { break }
            if msg["message_id"] as? String == messageId { break }
        }
    }

    // MARK: - tiny JSON-over-WS helpers

    private static func sendJSON(_ task: URLSessionWebSocketTask, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? ""
        try await task.send(.string(text))
    }

    /// Receives one frame as a JSON object, racing a timeout so a quiet socket can't
    /// hang the intent. Returns `[:]` for non-JSON frames.
    private static func receiveJSON(_ task: URLSessionWebSocketTask, timeout: TimeInterval = 5.0) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = Data()
                }
                return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ControlError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
