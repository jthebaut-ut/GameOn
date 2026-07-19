import Foundation

/// Client-side fan display-name / @handle validation.
/// Signup/onboarding must keep using the strict helpers; edit flows use the `*ForEdit` variants.
enum FanIdentityValidation {

    static func validateDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Display name is required." }
        if ReservedNameValidation.containsReservedTerm(trimmed) {
            return ReservedNameValidation.rejectionMessage
        }
        return nil
    }

    static func validateHandle(_ raw: String) -> String? {
        if let issue = FanGeoHandleRules.validate(raw) {
            return FanGeoHandleRules.validationMessage(for: issue)
        }
        return nil
    }

    /// Edit-screen display name: allow evolving an approved baseline; reject only newly introduced reserved tokens.
    static func validateDisplayNameForEdit(_ raw: String, original: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Display name is required." }
        return ReservedNameValidation.editReservedRejectionMessage(edited: trimmed, original: original)
    }

    /// Edit-screen handle: format rules always apply when changed; reserved tokens only when newly introduced.
    static func validateHandleForEdit(_ raw: String, original: String) -> String? {
        let handle = FanGeoHandleRules.normalizeForStorage(raw)
        let originalHandle = FanGeoHandleRules.normalizeForStorage(original)
        if handle == originalHandle {
            return nil
        }
        guard !handle.isEmpty else { return "Choose a @handle." }
        if let formatIssue = FanGeoHandleRules.validateFormat(raw) {
            return FanGeoHandleRules.validationMessage(for: formatIssue)
        }
        return ReservedNameValidation.editReservedRejectionMessage(edited: handle, original: originalHandle)
    }
}
