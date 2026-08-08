import Foundation

enum ChatReplySelfTests {
    static func runAll() {
        let text = ChatReplyPreviewFormatting.previewLine(body: "Meet at 7 PM?", languageCode: "en")
        assert(text == "Meet at 7 PM?", "plain text reply preview")

        let locationBody = "x\n\(ChatLocationShareMessage.sentinel){}"
        let location = ChatReplyPreviewFormatting.previewLine(body: locationBody, languageCode: "en")
        assert(
            location == L10n.t("chat_reply_preview_shared_location", languageCode: "en"),
            "location reply preview"
        )
        assert(!location.contains("1.0") && !location.contains("2.0"), "location preview must omit coordinates")

        let liveBody = "x\n\(ChatLiveLocationShareMessage.sentinel){}"
        let live = ChatReplyPreviewFormatting.previewLine(body: liveBody, languageCode: "en")
        assert(live == L10n.t("chat_reply_preview_live_location", languageCode: "en"), "live location reply preview")

        let omwBody = "x\n\(ChatOnMyWayMessage.sentinel){}"
        let omw = ChatReplyPreviewFormatting.previewLine(body: omwBody, languageCode: "en")
        assert(omw == L10n.t("chat_reply_preview_on_my_way", languageCode: "en"), "on my way reply preview")

        let pollBody = "x\n\(PickupGamePollMessage.sentinel){}"
        let poll = ChatReplyPreviewFormatting.previewLine(body: pollBody, languageCode: "en")
        assert(poll == L10n.t("chat_reply_preview_poll", languageCode: "en"), "poll reply preview")

        assert(
            ChatReplyPreviewFormatting.isReplyEligible(
                body: "hello",
                messageType: "text",
                isDeleted: false,
                deletedAt: nil
            )
        )
        assert(
            !ChatReplyPreviewFormatting.isReplyEligible(
                body: "joined",
                messageType: "system",
                isDeleted: false,
                deletedAt: nil
            )
        )
        assert(
            !ChatReplyPreviewFormatting.isReplyEligible(
                body: "hello",
                messageType: "text",
                isDeleted: true,
                deletedAt: nil
            )
        )

        let collapsed = ChatReplyPreviewFormatting.collapseToSingleLine("a\nb\nc", maxChars: 120)
        assert(collapsed == "a b c", "collapse newlines")

        let unavailable = ChatReplyReference.unavailable(
            originalMessageId: UUID(),
            languageCode: "en"
        )
        assert(unavailable.availability == .unavailable)
        assert(unavailable.previewLine == L10n.t("chat_reply_original_unavailable", languageCode: "en"))
    }
}
