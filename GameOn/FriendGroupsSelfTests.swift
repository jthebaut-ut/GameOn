import Foundation

#if DEBUG
enum FriendGroupsSelfTests {
    static func runAll() {
        decodeGroupRow()
        memberCountPresentation()
        selectionState()
        multiGroupMembershipIds()
        stableMemberIds()
        emptyStateCopyKeys()
        nameValidation()
        artworkResolverDeterministic()
        artworkResolverKeywordThemes()
        artworkResolverTestMatrix()
        print("[FriendGroupsSelfTests] ALL PASSED")
    }

    private static func decodeGroupRow() {
        let json = """
        {"id":"11111111-1111-4111-8111-111111111111","name":"Soccer Friends","member_count":8,"created_at":"2026-08-10T12:00:00.000Z","updated_at":"2026-08-10T12:00:00.000Z"}
        """.data(using: .utf8)!
        struct Row: Decodable {
            let id: UUID
            let name: String
            let member_count: Int
            let created_at: String?
            let updated_at: String?
        }
        let row = try! JSONDecoder().decode(Row.self, from: json)
        precondition(row.name == "Soccer Friends")
        precondition(row.member_count == 8)
        let group = FriendGroup(
            id: row.id,
            name: row.name,
            memberCount: row.member_count,
            createdAt: FriendGroupService.parseDate(row.created_at),
            updatedAt: FriendGroupService.parseDate(row.updated_at)
        )
        precondition(group.id == row.id)
        precondition(FriendGroupSummary(group).memberCount == 8)
    }

    private static func memberCountPresentation() {
        let one = FriendGroupPresentation.memberCountLabel(count: 1, languageCode: "en")
        precondition(!one.isEmpty)
        let many = FriendGroupPresentation.memberCountLabel(count: 8, languageCode: "en")
        precondition(many.contains("8") || many.lowercased().contains("friend"))
    }

    private static func selectionState() {
        let store = FriendGroupSelectionStore()
        let a = UUID()
        let b = UUID()
        store.toggle(a)
        store.toggle(b)
        precondition(store.selectedCount == 2)
        store.toggle(a)
        precondition(store.selectedCount == 1)
        precondition(store.isSelected(b))
        store.clear()
        precondition(store.selectedCount == 0)
    }

    private static func multiGroupMembershipIds() {
        let g1 = UUID()
        let g2 = UUID()
        var selected: Set<UUID> = [g1]
        selected.insert(g2)
        selected.insert(g1)
        precondition(selected.count == 2)
        precondition(selected.contains(g1) && selected.contains(g2))
    }

    private static func stableMemberIds() {
        let groupId = UUID()
        let friendId = UUID()
        let member = FriendGroupMember(groupId: groupId, friendUserId: friendId, createdAt: nil)
        let again = FriendGroupMember(groupId: groupId, friendUserId: friendId, createdAt: Date())
        precondition(member.id == again.id)
    }

    private static func emptyStateCopyKeys() {
        let keys = [
            "friend_groups_title",
            "friend_groups_groups",
            "friend_groups_all_friends",
            "friend_groups_new_group",
            "friend_groups_create_title",
            "friend_groups_name_label",
            "friend_groups_add_friends",
            "friend_groups_add_to_group_title",
            "friend_groups_remove_from_group",
            "friend_groups_rename",
            "friend_groups_delete",
            "friend_groups_select_all",
            "friend_groups_empty_title",
            "friend_groups_empty_body",
            "friend_groups_create_new_group",
            "friend_groups_create_hero_body",
            "friend_groups_privacy_title",
            "friend_groups_privacy_body",
            "friend_groups_no_members",
            "friend_groups_delete_message",
        ]
        for key in keys {
            let value = L10n.t(key, languageCode: "en")
            precondition(value != key, "missing localization key \(key)")
        }
    }

    private static func nameValidation() {
        precondition(FriendGroupNameValidation.isValid("Soccer Friends"))
        precondition(!FriendGroupNameValidation.isValid("   "))
        precondition(!FriendGroupNameValidation.isValid(String(repeating: "a", count: 61)))
        precondition(FriendGroupNameValidation.normalized("  Work  ") == "Work")
    }

    private static func artworkResolverDeterministic() {
        let a = FriendGroupArtworkResolver.resolve(groupName: "Weekend Crew")
        let b = FriendGroupArtworkResolver.resolve(groupName: "Weekend Crew")
        precondition(a.category == b.category)
        precondition(a.systemImage == b.systemImage)
        precondition(!a.systemImage.isEmpty)
        precondition(a.category == .friends)
    }

    private static func artworkResolverKeywordThemes() {
        precondition(FriendGroupArtworkResolver.resolve(groupName: "Soccer Friends").category == .soccer)
        precondition(FriendGroupArtworkResolver.resolve(groupName: "Utah Ski Trip").category == .ski)
        precondition(FriendGroupArtworkResolver.resolve(groupName: "Family").category == .family)
        precondition(FriendGroupArtworkResolver.resolve(groupName: "School Class").category == .school)
        precondition(FriendGroupArtworkResolver.resolve(groupName: "Basketball Night").category == .basketball)
        precondition(FriendGroupArtworkResolver.resolve(groupName: "Family!!!").category == .family)
        precondition(FriendGroupArtworkResolver.normalize("My Family.") == "my family")
    }

    private static func artworkResolverTestMatrix() {
        let cases: [(String, FriendGroupArtworkResolver.Category)] = [
            ("Family", .family),
            ("My Family", .family),
            ("Soccer Parents", .soccer),
            ("Utah Soccer", .soccer),
            ("Basketball Team", .basketball),
            ("Work", .work),
            ("Office Friends", .work),
            ("School Parents", .school),
            ("Church", .church),
            ("Vacation", .travel),
            ("Travel", .travel),
            ("BBQ Friends", .food),
            ("Hiking", .outdoors),
            ("Utah", .outdoors),
            ("Gaming", .friends),
            ("Friends", .friends),
            ("Best Friends", .friends),
            ("Unknown Group", .friends),
        ]
        for (name, expected) in cases {
            let resolved = FriendGroupArtworkResolver.resolve(groupName: name)
            precondition(
                resolved.category == expected,
                "Expected \(expected.rawValue) for '\(name)', got \(resolved.category.rawValue)"
            )
            precondition(!resolved.systemImage.isEmpty)
            precondition(
                !L10n.t(resolved.accessibilityCategoryKey, languageCode: "en").isEmpty
            )
        }
    }
}
#endif
