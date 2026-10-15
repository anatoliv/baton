import Foundation

@MainActor
enum BatonInterpreterTools {
    static func devices() throws -> String {
        try String(decoding: JSONEncoder().encode(InterpreterDevices.all()), as: UTF8.self)
    }

    static func definitions() -> [[String: Any]] {
        let string: [String: Any] = ["type": "string", "description": "Exact session UUID, device UID, or service URL as required by this field; session/device values come from the preceding interpretation call."]
        let lane: [String: Any] = ["type": "string", "enum": ["incoming", "outgoing"], "description": "incoming routes translated meeting speech to headphones; outgoing routes your translated microphone speech to the meeting virtual device."]
        let generation: [String: Any] = ["type": "integer", "minimum": 0, "description": "Current lane generation returned by open/configure/status. Cancellation invalidates this generation."]
        return [
            tool("interpretation_devices", "List stable audio device UIDs and input/output/virtual capabilities. Outgoing speech requires a separate duplex virtual device.", [:], []),
            tool("interpretation_open", "Open two persistent interpretation routes. Returns a short-lived credential for separate authenticated local streams. No audio is carried over MCP.", ["incoming_device_uid": string, "outgoing_device_uid": string, "voice_engine": ["type": "string", "enum": ["native", "kokoro"], "description": "Speech renderer for text commits: native uses macOS voices; kokoro uses the supplied tts_url. Direct PCM bypasses synthesis."], "tts_url": string], ["incoming_device_uid", "outgoing_device_uid"]),
            tool("interpretation_status", "Read current interpreter connection state and lane generations.", [:], []),
            tool("interpretation_cancel", "Immediately stop and invalidate one lane. Does not stop the other lane.", ["session_id": string, "lane": lane, "generation": generation], ["session_id", "lane", "generation"]),
            tool("interpretation_configure", "Reopen a stopped lane on a selected device. Returns a new generation and short-lived connection credential. Does not replay prior speech.", ["session_id": string, "lane": lane, "device_uid": string], ["session_id", "lane", "device_uid"]),
            tool("interpretation_close", "Stop both routes and release interpretation focus. Clients should drain before normal close.", ["session_id": string], ["session_id"]),
        ]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }
}
