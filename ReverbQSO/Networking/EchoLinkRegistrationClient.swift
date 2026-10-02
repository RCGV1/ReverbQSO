// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum EchoLinkRegistrationError: LocalizedError {
    case invalidCallsign
    case invalidEmail
    case invalidPassword
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallsign: "Enter your amateur radio callsign."
        case .invalidEmail: "Enter a valid email address."
        case .invalidPassword: "Choose a password with 5–14 ASCII characters."
        case .invalidResponse: "EchoLink did not return a registration result. Try again."
        case .server(let message): message
        }
    }
}

/// Creates a native registration request from the public EchoLink client wire contract.
struct EchoLinkRegistrationClient {
    private static let softwareTagKey = "echolinkRegistrationSoftwareTag"
    private let endpoint: URL
    private let session: URLSession
    private let softwareTag: String

    init(
        endpoint: URL = URL(string: "https://www.echolink.org/validation/registerNode.jsp")!,
        session: URLSession = URLSession(configuration: .ephemeral),
        softwareTag: String? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.softwareTag = softwareTag ?? Self.loadOrCreateSoftwareTag()
    }

    static func loadOrCreateSoftwareTag(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: softwareTagKey), !saved.isEmpty {
            return saved
        }
        let generated = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22))
        defaults.set(generated, forKey: softwareTagKey)
        return generated
    }

    func register(callsign: String, email: String, password: String) async throws -> String {
        let request = try makeRequest(callsign: callsign, email: email, password: password)
        let (data, response) = try await session.data(for: request)
        return try parseResponse(data, response: response)
    }

    func makeRequest(callsign: String, email: String, password: String) throws -> URLRequest {
        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let baseCallsign = normalizedCallsign.hasSuffix("-L") || normalizedCallsign.hasSuffix("-R")
            ? String(normalizedCallsign.dropLast(2)) : normalizedCallsign
        // Validate the base amateur callsign shape; the server verifies license
        // eligibility. Preserve a link/repeater suffix in the registration form.
        guard (3...7).contains(baseCallsign.count),
              baseCallsign.range(
                of: "^(?:[A-Z]{1,2}|[0-9][A-Z]{1,2}|[A-Z][0-9])[0-9]{1,2}[A-Z]{1,4}$",
                options: .regularExpression
              ) != nil else {
            throw EchoLinkRegistrationError.invalidCallsign
        }
        let emailParts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard !normalizedEmail.contains(where: \.isWhitespace), emailParts.count == 2,
              emailParts.allSatisfy({ !$0.isEmpty }) else {
            throw EchoLinkRegistrationError.invalidEmail
        }
        guard (5...14).contains(normalizedPassword.utf8.count),
              normalizedPassword.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw EchoLinkRegistrationError.invalidPassword
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "callsign", value: normalizedCallsign),
            URLQueryItem(name: "password", value: normalizedPassword),
            URLQueryItem(name: "location", value: "ReverbQSO User"),
            URLQueryItem(name: "swtag", value: softwareTag),
            URLQueryItem(name: "email", value: normalizedEmail),
            URLQueryItem(name: "apiver", value: "2")
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    func parseResponse(_ data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty, !result.contains("<") else {
            throw EchoLinkRegistrationError.invalidResponse
        }
        if result == "OK" {
            return "Check your email for EchoLink's validation instructions."
        }
        if result == "Validated" {
            return "Your callsign is validated. You can sign in now."
        }
        if result.hasPrefix("Callsign already registered") {
            return "Your callsign is already registered. Sign in if it is validated, or continue EchoLink validation."
        }
        throw EchoLinkRegistrationError.server(result)
    }
}
