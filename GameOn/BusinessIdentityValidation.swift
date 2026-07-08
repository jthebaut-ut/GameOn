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
}
