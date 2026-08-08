import Foundation

enum PickupGamePollSelfTests {
    static func runAll() {
        testValidationTrimsAndRejectsDuplicates()
        testValidationRejectsEmptyAndWhitespace()
        testModerationReuse()
        testEncodeDecodeRoundTrip()
        testAccessGate()
    }

    private static func testValidationTrimsAndRejectsDuplicates() {
        let issue = PickupGamePollValidation.validate(
            question: "  Who brings drinks?  ",
            options: [" Me ", "me", "You"]
        )
        precondition(issue == .duplicateOptions, "Expected duplicate options")
    }

    private static func testValidationRejectsEmptyAndWhitespace() {
        precondition(
            PickupGamePollValidation.validate(question: "   ", options: ["A", "B"]) == .emptyQuestion
        )
        precondition(
            PickupGamePollValidation.validate(question: "Q?", options: [" ", "B"]) == .emptyOption(index: 0)
        )
        precondition(
            PickupGamePollValidation.validate(question: "Q?", options: ["A"]) == .tooFewOptions
        )
    }

    private static func testModerationReuse() {
        let issue = PickupGamePollValidation.validate(
            question: "What the fuck should we do?",
            options: ["Play", "Rest"]
        )
        precondition(issue == .moderationRejected, "Expected moderation rejection via ModerationService")
        let message = PickupGamePollValidation.userMessage(for: .moderationRejected)
        precondition(message.contains("isn't allowed") || message.contains("isn’t allowed"))
    }

    private static func testEncodeDecodeRoundTrip() {
        let pollId = UUID()
        let payload = PickupGamePollPayload(
            pollId: pollId,
            question: "Bring snacks?",
            allowMultiple: false,
            isAnonymous: true,
            autoCloseAtGameStart: true,
            closesAt: Date().addingTimeInterval(3600),
            createdByName: "Alex"
        )
        let body = PickupGamePollMessage.encodeBody(payload: payload)
        let decoded = PickupGamePollMessage.decode(from: body)
        precondition(decoded?.pollId == pollId)
        precondition(decoded?.question == "Bring snacks?")
        precondition(decoded?.isAnonymous == true)
        precondition(PickupGamePollMessage.inboxPreview(from: body) != nil)
    }

    private static func testAccessGate() {
        precondition(
            PickupGamePollAccess.canCreate(
                isOrganizer: true,
                permission: .organizerOnly,
                isApprovedParticipant: false
            )
        )
        precondition(
            !PickupGamePollAccess.canCreate(
                isOrganizer: false,
                permission: .organizerOnly,
                isApprovedParticipant: true
            )
        )
        precondition(
            PickupGamePollAccess.canCreate(
                isOrganizer: false,
                permission: .approvedPlayers,
                isApprovedParticipant: true
            )
        )
        precondition(
            !PickupGamePollAccess.canCreate(
                isOrganizer: false,
                permission: .approvedPlayers,
                isApprovedParticipant: false
            )
        )
        precondition(PickupGamePollAccess.canModerate(isOrganizer: true))
        precondition(!PickupGamePollAccess.canModerate(isOrganizer: false))
        precondition(PickupPollCreatePermission.resolved(nil) == .organizerOnly)
        precondition(PickupPollCreatePermission.resolved("approved_players") == .approvedPlayers)
    }
}
