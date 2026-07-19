import Foundation

/// Client-side validation for business display name and @handle during signup.
enum BusinessIdentityValidation {

    static func validateBusinessName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Business name is required." }
        if ReservedNameValidation.containsReservedTerm(trimmed) {
            return ReservedNameValidation.rejectionMessage
        }
        return nil
    }

    static func validateBusinessHandle(_ raw: String) -> String? {
        if let issue = FanGeoHandleRules.validate(raw) {
            return FanGeoHandleRules.validationMessage(for: issue)
        }
        if ReservedNameValidation.containsReservedTerm(raw) {
            return ReservedNameValidation.rejectionMessage
        }
        return nil
    }

    /// Edit-screen name: allow evolving an approved baseline; reject only newly introduced reserved tokens.
    static func validateBusinessNameForEdit(_ raw: String, original: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Business name is required." }
        return ReservedNameValidation.editReservedRejectionMessage(edited: trimmed, original: original)
    }

    /// Edit-screen handle: format rules when changed; reserved tokens only when newly introduced.
    static func validateBusinessHandleForEdit(_ raw: String, original: String) -> String? {
        let handle = FanGeoHandleRules.normalizeForStorage(raw)
        let originalHandle = FanGeoHandleRules.normalizeForStorage(original)
        if handle == originalHandle {
            return nil
        }
        guard !handle.isEmpty else { return "Business @handle is required." }
        if let formatIssue = FanGeoHandleRules.validateFormat(raw) {
            return FanGeoHandleRules.validationMessage(for: formatIssue)
        }
        return ReservedNameValidation.editReservedRejectionMessage(edited: handle, original: originalHandle)
    }
}
