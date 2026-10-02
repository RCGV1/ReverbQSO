// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum CallCQBackendError: LocalizedError {
    case authenticatedTransportUnavailable
    case allowListEnabled
    case noAllowedNodeTypes
    case noAllowedCountries
    case conferenceHostingActive
    case transportUnavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .authenticatedTransportUnavailable:
            "Call CQ needs an authenticated EchoLink matching transport that is not available in this native session yet."
        case .allowListEnabled:
            "Call CQ is unavailable while Only Allow Listed Callsigns is enabled in Call Restrictions."
        case .noAllowedNodeTypes:
            "Choose at least one node type allowed by Call Restrictions."
        case .noAllowedCountries:
            "The selected countries are blocked in Call Restrictions."
        case .conferenceHostingActive:
            "Stop conference hosting before using Call CQ."
        case .transportUnavailable:
            "Sign in again so Call CQ can use the selected network method."
        case .invalidResponse:
            "The Call CQ service returned an invalid response."
        case .server(let message):
            message
        }
    }
}

struct CallCQRegistration: Codable, Equatable {
    let callsign: String
    let nodeType: String
    let internetAddress: String?
    let countryCode: String
    let isReachable: Bool
    let acceptCountryCodes: [String]
    let acceptLanguageCodes: [String]
    let declineCallsigns: [String]
    let acceptNodeTypes: [String]

    static func make(
        callsign: String,
        preferences: CallCQPreferences,
        policy: CallAccessPolicy,
        recentCallsigns: [String],
        transport: EchoLinkEffectiveTransport
    ) throws -> Self {
        let outgoingPolicy = policy.applyToOutgoing
        guard !outgoingPolicy || !policy.useAllowList else { throw CallCQBackendError.allowListEnabled }
        let types = outgoingPolicy ? preferences.nodeTypes.intersection(policy.allowedTypes) : preferences.nodeTypes
        guard !types.isEmpty else { throw CallCQBackendError.noAllowedNodeTypes }

        let blockedCountries = outgoingPolicy
            ? Set(policy.blockedCountries.map(CallAccessPolicy.normalize)) : []
        let acceptedCountries: Set<String>
        if preferences.countryCodes.isEmpty, !blockedCountries.isEmpty {
            acceptedCountries = Set(Locale.Region.isoRegions.map(\.identifier)).subtracting(blockedCountries)
        } else {
            acceptedCountries = Set(preferences.countryCodes.map(CallAccessPolicy.normalize))
                .subtracting(blockedCountries)
        }
        if !preferences.countryCodes.isEmpty, acceptedCountries.isEmpty {
            throw CallCQBackendError.noAllowedCountries
        }

        let configuration = transport.configuration
        let address: String?
        let reachable: Bool
        switch configuration.mode {
        case .direct:
            address = nil
            reachable = true
        case .relay:
            address = transport.relayAddress
            reachable = false
        case .publicProxy, .customProxy:
            address = configuration.host.isEmpty ? nil : configuration.host
            reachable = true
        case .automatic:
            throw CallCQBackendError.transportUnavailable
        }

        var declined = outgoingPolicy
            ? Set(policy.blockedCallsigns.map(CallAccessPolicy.normalize)) : []
        if preferences.avoidRecentContacts {
            declined.formUnion(recentCallsigns.map(CallAccessPolicy.normalize))
        }
        return Self(
            callsign: CallAccessPolicy.normalize(callsign),
            nodeType: "U",
            internetAddress: address,
            countryCode: ITUCallsignCountryResolver.countryCode(for: callsign) ?? "",
            isReachable: reachable,
            acceptCountryCodes: acceptedCountries.sorted(),
            acceptLanguageCodes: preferences.languageCodes.sorted(),
            declineCallsigns: declined.sorted(),
            acceptNodeTypes: [Station.StationType.user, .link, .repeater]
                .filter(types.contains)
                .map(\.rawValue)
        )
    }

    func replacingInternetAddress(_ address: String) -> Self {
        Self(
            callsign: callsign, nodeType: nodeType, internetAddress: address,
            countryCode: countryCode, isReachable: isReachable,
            acceptCountryCodes: acceptCountryCodes, acceptLanguageCodes: acceptLanguageCodes,
            declineCallsigns: declineCallsigns, acceptNodeTypes: acceptNodeTypes
        )
    }
}

enum CallCQIPv4Resolver {
    static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    static func resolve(_ host: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0 else {
                throw CallCQBackendError.transportUnavailable
            }
            defer { if let result { freeaddrinfo(result) } }
            var cursor = result
            while let entry = cursor {
                if let address = entry.pointee.ai_addr {
                    let socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
                    var ipv4 = socketAddress.pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil {
                        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                    }
                }
                cursor = entry.pointee.ai_next
            }
            throw CallCQBackendError.transportUnavailable
        }.value
    }
}

enum CallCQOperation {
    case register(CallCQRegistration)
    case find(callsign: String)
    case cancel(callsign: String)

    fileprivate var path: String {
        switch self {
        case .register: "register"
        case .find: "find"
        case .cancel: "cancel"
        }
    }

    fileprivate func body(using encoder: JSONEncoder) throws -> Data {
        switch self {
        case .register(let registration): try encoder.encode(registration)
        case .find(let callsign), .cancel(let callsign):
            try encoder.encode(["callsign": CallAccessPolicy.normalize(callsign)])
        }
    }
}

enum CallCQRequestFactory {
    static let baseURL = URL(string: "https://www.echolink.org/cqqserver/cqq/")!

    static func request(operation: CallCQOperation, password: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(operation.path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Data(password.utf8).base64EncodedString(), forHTTPHeaderField: "X-EchoLink-Auth")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try operation.body(using: encoder)
        return request
    }
}

private final class CallCQURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let redirectHost = request.url?.host?.lowercased()
        completionHandler(
            originalHost == redirectHost && request.url?.scheme?.lowercased() == "https"
                ? request : nil
        )
    }
}

enum CallCQPollResponse: Equatable {
    case waiting
    case matched(callsign: String, internetAddress: String)
}

enum CallCQResponseParser {
    static func validateRegistration(_ data: Data) throws {
        let object = try jsonObject(data)
        if let error = object["error"] as? String { throw CallCQBackendError.server(error) }
    }

    static func parse(_ data: Data) throws -> CallCQPollResponse {
        let object = try jsonObject(data)
        if let error = object["error"] as? String {
            if error == "No match" { return .waiting }
            throw CallCQBackendError.server(error)
        }
        guard let callsign = object["matchedCallsign"] as? String,
              let address = object["matchedInternetAddress"] as? String else { return .waiting }
        return .matched(callsign: callsign, internetAddress: address)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CallCQBackendError.invalidResponse
        }
        return value
    }
}

@MainActor
protocol CallCQClientProtocol: Sendable {
    func register(_ registration: CallCQRegistration, password: String) async throws
    func find(callsign: String, password: String) async throws -> CallCQPollResponse
    func cancel(callsign: String, password: String) async
}

struct CallCQHTTPClient: CallCQClientProtocol, Sendable {
    let session: URLSession

    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: CallCQURLSessionDelegate(), delegateQueue: nil)
    }()

    init(session: URLSession = secureSession) { self.session = session }

    func register(_ registration: CallCQRegistration, password: String) async throws {
        let (data, response) = try await session.data(for: CallCQRequestFactory.request(operation: .register(registration), password: password))
        try validateHTTP(response)
        try validateBody(data)
        try CallCQResponseParser.validateRegistration(data)
    }

    func find(callsign: String, password: String) async throws -> CallCQPollResponse {
        let (data, response) = try await session.data(for: CallCQRequestFactory.request(operation: .find(callsign: callsign), password: password))
        try validateHTTP(response)
        try validateBody(data)
        return try CallCQResponseParser.parse(data)
    }

    func cancel(callsign: String, password: String) async {
        guard let request = try? CallCQRequestFactory.request(operation: .cancel(callsign: callsign), password: password) else { return }
        _ = try? await session.data(for: request)
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CallCQBackendError.invalidResponse
        }
    }

    private func validateBody(_ data: Data) throws {
        guard data.count <= 65_536 else { throw CallCQBackendError.invalidResponse }
    }
}
