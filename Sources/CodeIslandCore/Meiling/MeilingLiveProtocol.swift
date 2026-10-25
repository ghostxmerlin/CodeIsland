import Foundation

/// Gemini Live messages for 美玲 on the Mac (the same wire as luna-work app/voice/gemini_meiling_protocol.cpp).
///   dictation  gemini-3.5-transcribe-live: PCM16 16 kHz in, inputTranscription (final) / interim text out
///   meeting    gemini-3.5-live-translate-preview: PCM16 16 kHz in, PCM16 24 kHz + both transcriptions out
public enum MeilingLiveProtocol {
    public static let host = "generativelanguage.googleapis.com"
    public static let path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    public static let transcribeModel = "gemini-3.5-transcribe-live"
    public static let translateModel = "gemini-3.5-live-translate-preview"

    public static func url(apiKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }

    public static func transcribeSetup(model: String = transcribeModel, vocabulary: [String]) -> Data {
        var transcription: [String: Any] = ["languageCodes": [String](), "mode": "SMART"]
        if !vocabulary.isEmpty { transcription["customVocabulary"] = vocabulary }
        return json(["setup": ["model": "models/" + model,
                               "generationConfig": ["responseModalities": ["TEXT"]],
                               "inputAudioTranscription": transcription]])
    }

    /// Both transcriptions sit at setup level: under generationConfig the server closes with 1007.
    public static func translateSetup(model: String = translateModel, target: String, resumeHandle: String?) -> Data {
        var resumption: [String: Any] = [:]
        if let resumeHandle, !resumeHandle.isEmpty { resumption["handle"] = resumeHandle }
        return json(["setup": ["model": "models/" + model,
                               "generationConfig": ["responseModalities": ["AUDIO"],
                                                    "translationConfig": ["targetLanguageCode": target,
                                                                          "echoTargetLanguage": false]],
                               "inputAudioTranscription": [String: Any](),
                               "outputAudioTranscription": [String: Any](),
                               "sessionResumption": resumption]])
    }

    public static func audioMessage(_ pcm16k: [Int16]) -> Data {
        let bytes = pcm16k.withUnsafeBufferPointer { Data(buffer: $0) }  // little-endian on Apple silicon and x86
        return json(["realtimeInput": ["audio": ["data": bytes.base64EncodedString(),
                                                 "mimeType": "audio/pcm;rate=16000"]]])
    }

    public static let audioStreamEnd = json(["realtimeInput": ["audioStreamEnd": true]])

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// One server message, flattened. Empty strings mean "not present".
public struct MeilingServerMessage: Equatable, Sendable {
    public var setupComplete = false, goAway = false, turnComplete = false, generationComplete = false
    public var error: String?
    public var resumable = false
    public var resumptionHandle = ""
    public var interimInput = "", finalInput = "", outputText = ""
    public var finalInputPresent = false
    public var languageCode = ""
    public var audio24k: [Int16] = []

    public init() {}

    public static func parse(_ data: Data) -> MeilingServerMessage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var m = MeilingServerMessage()
        m.setupComplete = root["setupComplete"] != nil
        m.goAway = root["goAway"] != nil
        if let error = root["error"] as? [String: Any] {
            m.error = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Gemini error"
        }
        if let update = root["sessionResumptionUpdate"] as? [String: Any] {
            m.resumable = update["resumable"] as? Bool ?? false
            m.resumptionHandle = update["newHandle"] as? String ?? ""
        }
        guard let content = root["serverContent"] as? [String: Any] else { return m }
        m.turnComplete = content["turnComplete"] as? Bool ?? false
        m.generationComplete = content["generationComplete"] as? Bool ?? false
        m.interimInput = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String ?? ""
        if let final = content["inputTranscription"] as? [String: Any] {
            m.finalInputPresent = true
            m.finalInput = final["text"] as? String ?? ""
            m.languageCode = final["languageCode"] as? String ?? ""
        }
        m.outputText = (content["outputTranscription"] as? [String: Any])?["text"] as? String ?? ""
        let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  (inline["mimeType"] as? String ?? "").hasPrefix("audio/pcm"),
                  let b64 = inline["data"] as? String,
                  let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            let count = bytes.count / 2
            bytes.withUnsafeBytes { raw in
                for i in 0..<count { m.audio24k.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) }
            }
        }
        return m
    }
}
