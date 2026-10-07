import Foundation

/// Passive text cues and insertion have different caret requirements. Explicit
/// read-only/password metadata always wins over advertised write capabilities.
public enum AccessibleTextCapturePolicy {
    public enum Editability: Equatable { case editable, readOnly, secure }

    public static func editability(role: String?, subrole: String?, enabled: Bool?,
                                   editable: Bool?, valueWritable: Bool,
                                   selectedTextWritable: Bool) -> Editability {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .secure }
        guard enabled != false, editable != false else { return .readOnly }
        let textRole = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "")
        guard textRole || editable == true,
              editable == true || valueWritable || selectedTextWritable else { return .readOnly }
        return .editable
    }

    public static func selection(_ range: NSRange?, textLength: Int, required: Bool) -> NSRange? {
        if let range, range.location >= 0, range.length >= 0, range.location <= textLength,
           range.length <= textLength - range.location { return range }
        return required ? nil : NSRange(location: NSNotFound, length: 0)
    }
}
