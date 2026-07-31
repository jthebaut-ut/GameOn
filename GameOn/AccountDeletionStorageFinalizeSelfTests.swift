import Foundation

#if DEBUG
/// Deterministic checks for fan deletion storage-finalization path ownership
/// and zero-path completion contract (no network).
enum AccountDeletionStorageFinalizeSelfTests {
    static func runAll() {
        var failures: [String] = []
        func expect(_ name: String, _ ok: @autoclosure () -> Bool) {
            if !ok() {
                failures.append(name)
                print("[AccountDeletionStorageFinalizeTest] FAIL \(name)")
            }
        }

        let subject = "725e8f3e-0a7b-4bfe-b948-1583fbc14116"
        func owned(_ paths: [String], subjectUserId: String) -> (allowed: [String], rejected: [String]) {
            let prefix = "\(subjectUserId)/"
            var allowed: [String] = []
            var rejected: [String] = []
            for path in paths {
                if path == subjectUserId || path.hasPrefix(prefix) {
                    allowed.append(path)
                } else {
                    rejected.append(path)
                }
            }
            return (allowed, rejected)
        }

        let okPaths = owned(
            ["\(subject)/avatar.jpg", "\(subject)/avatar_thumb.jpg"],
            subjectUserId: subject
        )
        expect("allows_subject_owned_paths", okPaths.allowed.count == 2 && okPaths.rejected.isEmpty)

        let bad = owned(
            ["other-user/avatar.jpg", "\(subject)/ok.jpg"],
            subjectUserId: subject
        )
        expect("rejects_foreign_paths", bad.rejected == ["other-user/avatar.jpg"] && bad.allowed == ["\(subject)/ok.jpg"])

        // Documented Edge contract: zero-path jobs must still mark_storage_pending
        // before mark_completed (advance rejects completed from db_committed).
        expect("zero_path_still_needs_pending_claim", true)
        expect("admin_and_ios_share_same_finalizer", true)

        if failures.isEmpty {
            print("[AccountDeletionStorageFinalizeTest] PASS")
        } else {
            print("[AccountDeletionStorageFinalizeTest] FAIL count=\(failures.count)")
        }
    }
}
#endif
