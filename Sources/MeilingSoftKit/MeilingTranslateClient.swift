import CodeIslandCore
import Foundation

/// One REST call per translate talk (MeilingTranslate): the Chinese paragraph in, the English prompt out.
/// `done` runs on the main queue.
public enum MeilingTranslateClient {
    public static func translate(_ transcript: String, terminology: [String], apiKey: String,
                                 done: @escaping @Sendable (Result<String, MeilingTranslate.Failure>) -> Void) {
        var request = URLRequest(url: MeilingTranslate.endpoint(), timeoutInterval: MeilingTranslate.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = MeilingTranslate.requestBody(transcript: transcript, terminology: terminology)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, MeilingTranslate.Failure>
            if let error {
                result = .failure(.init(error.localizedDescription))
            } else {
                result = MeilingTranslate.parse(data ?? Data(), status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}
