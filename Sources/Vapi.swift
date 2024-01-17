import Combine
import Daily
import Foundation

public final class Vapi: CallClientDelegate {
    
    // MARK: - Supporting Types
    
    /// A configuration that contains the host URL and the client token.
    ///
    /// This configuration is serializable via `Codable`.
    public struct Configuration: Codable, Hashable, Sendable {
        public var host: String
        public var publicKey: String
        fileprivate static let defaultHost = "api.vapi.ai"
        
        init(publicKey: String, host: String) {
            self.host = host
            self.publicKey = publicKey
        }
    }
    
    public enum Event {
        case callDidStart
        case callDidEnd
        case transcript(Transcript)
        case functionCall(FunctionCall)
        case hang
        case error(Swift.Error)
    }
    
    // MARK: - Properties

    public let configuration: Configuration

    fileprivate let eventSubject = PassthroughSubject<Event, Never>()
    
    private let networkManager = NetworkManager()
    private var call: CallClient?
    
    // MARK: - Computed Properties
    
    private var publicKey: String {
        configuration.publicKey
    }
    
    /// A Combine publisher that clients can subscribe to for API events.
    public var eventPublisher: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Init
    
    public init(configuration: Configuration) {
        self.configuration = configuration
        
        Daily.setLogLevel(.off)
    }
    
    public convenience init(publicKey: String) {
        self.init(configuration: .init(publicKey: publicKey, host: Configuration.defaultHost))
    }
    
    public convenience init(publicKey: String, host: String? = nil) {
        self.init(configuration: .init(publicKey: publicKey, host: host ?? Configuration.defaultHost))
    }
    
    // MARK: - Instance Methods
    
    public func start(assistantId: String) async throws -> WebCallResponse {
        guard self.call == nil else {
            throw VapiError.existingCallInProgress
        }
        
        let body = ["assistantId": assistantId]
        
        return try await self.startCall(body: body)
    }
    
    public func start(assistant: [String: Any]) async throws -> WebCallResponse {
        guard self.call == nil else {
            throw VapiError.existingCallInProgress
        }
        
        let body = ["assistant": assistant]
        
        return try await self.startCall(body: body)
    }
    
    public func stop() {
        Task {
            do {
                try await call?.leave()
            } catch {
                self.callDidFail(with: error)
            }
        }
    }
    
    private func joinCall(with url: URL) {
        Task { @MainActor in
            do {
                let call = CallClient()
                call.delegate = self
                self.call = call
                
                _ = try await call.join(
                    url: url,
                    settings: .init(
                        inputs: .set(
                            camera: .set(.enabled(false)),
                            microphone: .set(.enabled(true))
                        )
                    )
                )
            } catch {
                callDidFail(with: error)
            }
        }
    }
    
    private func makeURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.host
        components.path = path
        return components.url
    }
    
    private func makeURLRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    private func startCall(body: [String: Any]) async throws -> WebCallResponse {
        guard let url = makeURL(for: "/call/web") else {
            callDidFail(with: VapiError.invalidURL)
            throw VapiError.customError("Unable to create web call")
        }
        
        var request = makeURLRequest(for: url)
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            self.callDidFail(with: error)
            throw VapiError.customError(error.localizedDescription)
        }
        
        do {
            let response: WebCallResponse = try await networkManager.perform(request: request)
            joinCall(with: response.webCallUrl)
            return response
        } catch {
            callDidFail(with: error)
            throw VapiError.customError(error.localizedDescription)
        }
    }
    
    private func unescapeAppMessage(_ jsonData: Data) -> Data {
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            return jsonData
        }

        // Remove the leading and trailing double quotes
        let trimmedString = jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // Replace escaped backslashes
        let unescapedString = trimmedString.replacingOccurrences(of: "\\\\", with: "\\")
        // Replace escaped double quotes
        let unescapedJSON = unescapedString.replacingOccurrences(of: "\\\"", with: "\"")

        let unescapedData = unescapedJSON.data(using: .utf8) ?? jsonData
        return unescapedData
    }
    
    // MARK: - CallClientDelegate
    
    func callDidJoin() {
        print("Successfully joined call.")
        
        self.eventSubject.send(.callDidStart)
    }
    
    func callDidLeave() {
        print("Successfully left call.")
        
        self.eventSubject.send(.callDidEnd)
        self.call = nil
    }
    
    func callDidFail(with error: Swift.Error) {
        print("Got error while joining/leaving call: \(error).")
        
        self.eventSubject.send(.error(error))
        self.call = nil
    }
    
    public func callClient(_ callClient: CallClient, participantUpdated participant: Participant) {
        let isPlayable = participant.media?.microphone.state == Daily.MediaState.playable
        let isVapiSpeaker = participant.info.username == "Vapi Speaker"
        let shouldSendAppMessage = isPlayable && isVapiSpeaker
        
        guard shouldSendAppMessage else {
            return
        }
        
        do {
            let message: [String: Any] = ["message": "playable"]
            let jsonData = try JSONSerialization.data(withJSONObject: message, options: [])
            
            Task {
                try await self.call?.sendAppMessage(json: jsonData, to: .all)
            }
        } catch {
            print("Error sending message: \(error.localizedDescription)")
        }
    }
    
    public func callClient(_ callClient: CallClient, callStateUpdated state: CallState) {
        switch (state) {
        case CallState.left:
            self.callDidLeave()
            break
        case CallState.joined:
            self.callDidJoin()
            break
        default:
            break
        }
    }
    
    public func callClient(_ callClient: Daily.CallClient, appMessageAsJson jsonData: Data, from participantID: Daily.ParticipantID) {
        do {
            let decoder = JSONDecoder()
            let unescapedData = unescapeAppMessage(jsonData)
            // Parse the JSON data generically to determine the type of event
            let appMessage = try decoder.decode(AppMessage.self, from: unescapedData)

            // Parse the JSON data again, this time using the specific type
            let event: Event
            switch appMessage.type {
            case .functionCall:
                guard let messageDictionary = try JSONSerialization.jsonObject(with: unescapedData, options: []) as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message isn't a valid JSON object")
                }
                
                guard let functionCallDictionary = messageDictionary["functionCall"] as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message missing functionCall")
                }
                
                guard let name = functionCallDictionary[FunctionCall.CodingKeys.name.stringValue] as? String else {
                    throw VapiError.decodingError(message: "App message missing name")
                }
                
                guard let parameters = functionCallDictionary[FunctionCall.CodingKeys.parameters.stringValue] as? [String: Any] else {
                    throw VapiError.decodingError(message: "App message missing parameters")
                }
                

                let functionCall = FunctionCall(name: name, parameters: parameters)
                event = Event.functionCall(functionCall)
            case .hang:
                event = Event.hang
            case .transcript:
                let transcript = try decoder.decode(Transcript.self, from: unescapedData)
                event = Event.transcript(transcript)
            }
            eventSubject.send(event)
        } catch {
            let messageText = String(data: jsonData, encoding: .utf8)
            print("Error parsing app message \"\(messageText)\": \(error.localizedDescription)")
        }
    }
}
