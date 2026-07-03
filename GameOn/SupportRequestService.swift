import Foundation
import Supabase

enum SupportRequestCategory: String, CaseIterable, Identifiable {
    case question = "question"
    case bugReport = "bug_report"
    case featureRequest = "feature_request"
    case businessSupport = "business_support"
    case accountIssue = "account_issue"
    case reportUser = "report_user"
    case reportVenue = "report_venue"
    case other = "other"

    var id: String { rawValue }

    /// Maps Contact Support UI issue types to legacy `support_requests.category` / edge-function values.
    var backendCategoryValue: String {
        switch self {
        case .question, .accountIssue:
            return "account_help"
        case .bugReport:
            return "technical_issue"
        case .featureRequest, .other:
            return "billing_other"
        case .businessSupport:
            return "venue_support"
        case .reportUser, .reportVenue:
            return "report_problem"
        }
    }

    var displayTitle: String {
        switch self {
        case .bugReport: return "Bug Report"
        case .question: return "Question"
        case .featureRequest: return "Feature Request"
        case .accountIssue: return "Account Issue"
        case .businessSupport: return "Business Support"
        case .reportUser: return "Report User"
        case .reportVenue: return "Report Venue"
        case .other: return "Other"
        }
    }

    /// Contextual hint under the issue type picker.
    var exampleHelperLine: String? {
        switch self {
        case .bugReport:
            return "Example: The map is frozen or messages are not loading."
        case .question:
            return "Example: How do I save a game to my calendar?"
        case .featureRequest:
            return "Example: I'd love a way to filter live games by league."
        case .accountIssue:
            return "Example: I cannot sign in or reset my password."
        case .businessSupport:
            return "Example: I need help claiming or editing my venue."
        case .reportUser:
            return "Example: A user is harassing me or posting inappropriate content."
        case .reportVenue:
            return "Example: A venue listing is incorrect or needs moderation."
        case .other:
            return "Example: General feedback or anything else we can help with."
        }
    }
}

enum SupportRequestSubmitError: LocalizedError, Equatable {
    case notSignedIn
    case rateLimited(String)
    case prohibitedContent
    case emailSendFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Please sign in to contact support."
        case .rateLimited(let message):
            return message
        case .prohibitedContent:
            return ModerationService.profanityRejectionUserMessage()
        case .emailSendFailed:
            return "Unable to send support request right now. Please try again later."
        }
    }
}

/// Persists optional `support_requests` rows and sends admin email via ``notify-support-request`` Edge Function.
struct SupportRequestService {
    static let messageMaxCharacters = 1000
    static let subjectMaxCharacters = 200

    private struct SupportRequestRow: Encodable {
        let user_id: UUID
        let category: String
        let subject: String
        let message: String
        let app_version: String?
    }

    private struct NotifySupportRequestPayload: Encodable {
        let category: String
        let subject: String
        let message: String
        let app_version: String?
        let client_timestamp: String
    }

    private struct NotifySupportRequestResponse: Decodable {
        let ok: Bool?
        let error: String?
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func appVersionLine() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let vt = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let bt = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if vt.isEmpty, bt.isEmpty { return "" }
        if bt.isEmpty { return vt }
        if vt.isEmpty { return "build \(bt)" }
        return "\(vt) (\(bt))"
    }

    func submitSupportRequest(
        category: SupportRequestCategory,
        subject: String,
        message: String,
        client: SupabaseClient
    ) async throws {
        let userId: UUID
        do {
            userId = try await client.auth.session.user.id
        } catch {
            throw SupportRequestSubmitError.notSignedIn
        }
        let sub = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sub.isEmpty, !msg.isEmpty else {
            throw SupportRequestSubmitError.emailSendFailed
        }
        if sub.count > Self.subjectMaxCharacters || msg.count > Self.messageMaxCharacters {
            throw SupportRequestSubmitError.emailSendFailed
        }

        if let limitMessage = RateLimitService.checkSupportRequestSubmit(userId: userId) {
#if DEBUG
            print("[Support] support request blocked by cooldown")
#endif
            throw SupportRequestSubmitError.rateLimited(limitMessage)
        }

        if ModerationService.containsProfanity(msg) {
            throw SupportRequestSubmitError.prohibitedContent
        }

#if DEBUG
        print("[Support] support request submitted")
#endif

        let appVer = Self.appVersionLine()
        let appVerField: String? = appVer.isEmpty ? nil : appVer
        let backendCategory = category.backendCategoryValue
        let row = SupportRequestRow(
            user_id: userId,
            category: backendCategory,
            subject: sub,
            message: msg,
            app_version: appVerField
        )

        do {
            _ = try await client
                .from("support_requests")
                .insert(row)
                .execute()
#if DEBUG
            SupportRequestDebugLog.logInsertSuccess(userId: userId)
#endif
        } catch {
#if DEBUG
            SupportRequestDebugLog.logInsertFailure(error)
#endif
        }

        let ts = Self.iso.string(from: Date())
        let payload = NotifySupportRequestPayload(
            category: backendCategory,
            subject: sub,
            message: msg,
            app_version: appVerField,
            client_timestamp: ts
        )

#if DEBUG
        print("[Support] support email queued")
        print("[SupportRequestDebug] category ui=\(category.rawValue) backend=\(backendCategory)")
        SupportRequestDebugLog.logEdgeFunctionInvokeStart()
#endif

        do {
            let response: NotifySupportRequestResponse = try await client.functions.invoke(
                "notify-support-request",
                options: FunctionInvokeOptions(method: .post, body: payload)
            )
#if DEBUG
            SupportRequestDebugLog.logEdgeFunctionDecodedResponse(
                ok: response.ok,
                error: response.error
            )
#endif
            if response.ok != true {
                if response.error == "prohibited_content" {
                    throw SupportRequestSubmitError.prohibitedContent
                }
                throw SupportRequestSubmitError.emailSendFailed
            }
        } catch let error as FunctionsError {
#if DEBUG
            SupportRequestDebugLog.logFunctionsError(error)
#endif
            if case let .httpError(_, data) = error,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["error"] as? String) == "prohibited_content" {
                throw SupportRequestSubmitError.prohibitedContent
            }
            throw SupportRequestSubmitError.emailSendFailed
        } catch let err as SupportRequestSubmitError {
#if DEBUG
            SupportRequestDebugLog.logThrownError(err)
#endif
            throw err
        } catch {
#if DEBUG
            SupportRequestDebugLog.logThrownError(error)
#endif
            throw SupportRequestSubmitError.emailSendFailed
        }

        RateLimitService.recordSupportRequestSubmit(userId: userId)
    }
}

#if DEBUG
private enum SupportRequestDebugLog {
    private static let edgeFunctionName = "notify-support-request"

    static var edgeFunctionURL: String {
        supabaseProjectURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/functions/v1/\(edgeFunctionName)"
    }

    static func logInsertSuccess(userId: UUID) {
        print("[SupportRequestDebug] support_requests insert success userId=\(userId.uuidString.lowercased())")
    }

    static func logInsertFailure(_ error: Error) {
        if let postgrest = error as? PostgrestError {
            print(
                "[SupportRequestDebug] support_requests insert failure " +
                "code=\(postgrest.code ?? "nil") " +
                "message=\(postgrest.message) " +
                "detail=\(postgrest.detail ?? "nil") " +
                "hint=\(postgrest.hint ?? "nil")"
            )
        } else {
            print(
                "[SupportRequestDebug] support_requests insert failure " +
                "error=\(error.localizedDescription) " +
                "type=\(String(reflecting: type(of: error))) " +
                "full=\(String(reflecting: error))"
            )
        }
    }

    static func logEdgeFunctionInvokeStart() {
        print("[SupportRequestDebug] edge function URL=\(edgeFunctionURL)")
    }

    static func logEdgeFunctionDecodedResponse(ok: Bool?, error: String?) {
        print(
            "[SupportRequestDebug] notify-support-request decoded response " +
            "ok=\(ok?.description ?? "nil") " +
            "error=\(error ?? "nil")"
        )
    }

    static func logFunctionsError(_ error: FunctionsError) {
        switch error {
        case .relayError:
            print(
                "[SupportRequestDebug] notify-support-request FunctionsError " +
                "localized=\(error.localizedDescription) " +
                "full=\(String(reflecting: error))"
            )
        case let .httpError(status, data):
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body len=\(data.count)>"
            print("[SupportRequestDebug] notify-support-request http status=\(status)")
            print("[SupportRequestDebug] notify-support-request http response body=\(body)")
            if let decoded = decodeNotifySupportError(from: data) {
                print(
                    "[SupportRequestDebug] notify-support-request decoded error field " +
                    "ok=\(decoded.ok?.description ?? "nil") " +
                    "error=\(decoded.error ?? "nil")"
                )
            }
            print(
                "[SupportRequestDebug] notify-support-request FunctionsError " +
                "localized=\(error.localizedDescription) " +
                "full=\(String(reflecting: error))"
            )
        @unknown default:
            print(
                "[SupportRequestDebug] notify-support-request FunctionsError " +
                "localized=\(error.localizedDescription) " +
                "full=\(String(reflecting: error))"
            )
        }
    }

    static func logThrownError(_ error: Error) {
        print(
            "[SupportRequestDebug] submitSupportRequest threw " +
            "error=\(error.localizedDescription) " +
            "type=\(String(reflecting: type(of: error))) " +
            "full=\(String(reflecting: error))"
        )
    }

    private struct NotifySupportErrorBody: Decodable {
        let ok: Bool?
        let error: String?
    }

    private static func decodeNotifySupportError(from data: Data) -> NotifySupportErrorBody? {
        try? JSONDecoder().decode(NotifySupportErrorBody.self, from: data)
    }
}
#endif
