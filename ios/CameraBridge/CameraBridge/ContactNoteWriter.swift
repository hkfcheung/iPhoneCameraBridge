import Foundation
import Contacts

/// Persists per-contact context captured from ESP32 audio.
///
/// We'd prefer `CNContact.note`, but that requires the
/// `com.apple.developer.contacts.notes` entitlement which Apple does not
/// grant to personal teams. Instead we stash the context in a labeled
/// `urlAddresses` entry — any plain string is accepted, it shows up on
/// the contact card, and no special entitlement is needed.
///
/// The entry is keyed by the label `"Context"`. On each capture we rewrite
/// that single entry, prepending the newest line so the latest context is
/// at the top.
final class ContactNoteWriter {

    private static let contextLabel = "Context"

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
            CNContactUrlAddressesKey as CNKeyDescriptor,
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
        let newLine = "[\(stamp)] \(text)"

        // Look for an existing "Context" entry; prepend new line if found.
        var updated = mutable.urlAddresses
        if let idx = updated.firstIndex(where: { $0.label == Self.contextLabel }) {
            let existing = updated[idx].value as String
            let merged   = newLine + "\n" + existing
            updated[idx] = CNLabeledValue(label: Self.contextLabel, value: merged as NSString)
        } else {
            updated.append(CNLabeledValue(label: Self.contextLabel, value: newLine as NSString))
        }
        mutable.urlAddresses = updated

        let req = CNSaveRequest()
        req.update(mutable)
        do {
            try store.execute(req)
            print("[ContactWriter] appended to \(fullName): \(newLine)")
            return true
        } catch {
            print("[ContactWriter] save failed for \(fullName): \(error.localizedDescription)")
            return false
        }
    }
}
