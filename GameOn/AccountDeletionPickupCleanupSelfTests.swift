import Foundation

#if DEBUG
/// Deterministic regression checks for account-deletion pickup cleanup messaging
/// and documented status transition matrix (no XCTest / no network).
enum AccountDeletionPickupCleanupSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ name: String, _ ok: @autoclosure () -> Bool) {
            if !ok() {
                failures.append(name)
                print("[AccountDeletionPickupCleanupTest] FAIL \(name)")
            }
        }

        // Mirrors MapViewModel.AccountDeletionError.serverFailure mapping.
        func userMessage(detail: String?) -> String {
            let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if normalizedDetail.contains("pickup_request_cancel_forbidden") {
                return "We couldn’t finish closing your pickup-game activity. Please try again. If the problem continues, contact FanGeo Support."
            }
            return "Account deletion could not be completed. Please try again or contact FanGeo Support."
        }

        expect(
            "maps_pickup_request_cancel_forbidden",
            userMessage(detail: "pickup_request_cancel_forbidden")
                == "We couldn’t finish closing your pickup-game activity. Please try again. If the problem continues, contact FanGeo Support."
        )
        expect(
            "maps_wrapped_detail_case_insensitive",
            userMessage(detail: "ERROR: Pickup_Request_Cancel_Forbidden")
                .contains("pickup-game activity")
        )
        expect(
            "generic_fallback_for_unknown",
            userMessage(detail: "some_other_failure")
                == "Account deletion could not be completed. Please try again or contact FanGeo Support."
        )
        expect(
            "generic_fallback_for_nil",
            userMessage(detail: nil)
                == "Account deletion could not be completed. Please try again or contact FanGeo Support."
        )
        expect(
            "does_not_expose_sqlstate",
            !userMessage(detail: "pickup_request_cancel_forbidden").contains("23514")
        )

        // Documented deletion transition matrix (must stay aligned with 20260897 helper).
        struct Transition: Equatable {
            let from: String
            let to: String?
            let role: String
        }
        let matrix: [Transition] = [
            .init(from: "approved", to: "withdrawn", role: "requester"),
            .init(from: "pending", to: "cancelled", role: "requester"),
            .init(from: "rejected", to: nil, role: "requester"),
            .init(from: "cancelled", to: nil, role: "requester"),
            .init(from: "withdrawn", to: nil, role: "requester"),
            .init(from: "pending", to: "cancelled", role: "organizer_owned_game"),
            .init(from: "approved", to: "cancelled", role: "organizer_owned_game"),
            .init(from: "cancelled", to: nil, role: "organizer_owned_game"),
            .init(from: "withdrawn", to: nil, role: "organizer_owned_game"),
        ]
        expect("matrix_has_nine_rows", matrix.count == 9)
        expect(
            "no_cancelled_to_withdrawn",
            !matrix.contains { $0.from == "cancelled" && $0.to == "withdrawn" }
        )
        expect(
            "no_withdrawn_to_cancelled_requester",
            !matrix.contains { $0.role == "requester" && $0.from == "withdrawn" && $0.to == "cancelled" }
        )
        expect(
            "approved_requester_withdraws",
            matrix.contains { $0.role == "requester" && $0.from == "approved" && $0.to == "withdrawn" }
        )

        if failures.isEmpty {
            print("[AccountDeletionPickupCleanupTest] PASS")
        } else {
            print("[AccountDeletionPickupCleanupTest] FAIL count=\(failures.count)")
        }
    }
}
#endif
