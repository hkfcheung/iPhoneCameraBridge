import Foundation
import Contacts

/// Appends a dated context line to a contact's `note` field.
///
/// NOTE: Reading/writing CNContact.note requires the entitlement
/// `com.apple.developer.contacts.notes`. Apple grants this only on request
/// for App Store builds; for personal/development builds signed with a
/// developer certificate, add the entitlement to the target and it just works.
/// Without the entitlement, CNContactNoteKey reads as an empty string and
/// save requests silently ignore the note change.
final class ContactNoteWriter {

    private let store = CNContactStore()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Returns true if a contact was found and the save request was executed.
    @discardableResult
    func appendNote(forFullName fullName: String, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
        ]

        let predicate = CNContact.predicateForContacts(matchingName: fullName)
        let matches: [CNContact]
        do {
            matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            print("[ContactWriter] lookup failed: \(error.localizedDescription)")
            return false
        }

        let parts = fullName.split(separator: " ").map(String.init)
        let first = parts.first ?? fullName
        let last  = parts.dropFirst().joined(separator: " ")

        let contact = matches.first { c in
            (c.givenName == first) && (last.isEmpty || c.familyName == last)
        } ?? matches.first

        guard let contact else {
            print("[ContactWriter] no contact for '\(fullName)'")
            return false
        }

        let mutable = contact.mutableCopy() as! CNMutableContact
        let stamp = Self.dateFormatter.string(from: Date())
        let line  = "[\(stamp)] \(text)"
        mutable.note = mutable.note.isEmpty ? line : mutable.note + "\n" + line

        let req = CNSaveRequest()
        req.update(mutable)
        do {
            try store.execute(req)
            print("[ContactWriter] appended to \(fullName): \(line)")
            return true
        } catch {
            print("[ContactWriter] save failed for \(fullName): \(error.localizedDescription)")
            return false
        }
    }
}
