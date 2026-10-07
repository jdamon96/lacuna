import XCTest
@testable import LacunaCore

final class AccessibleTextCapturePolicyTests: XCTestCase {
    func testPassiveCaptureDoesNotInventMissingOrInvalidCaret() {
        for selection in [nil, NSRange(location: 30, length: 0), NSRange(location: 2, length: 50)] {
            XCTAssertEqual(AccessibleTextCapturePolicy.selection(selection, textLength: 20, required: false),
                           NSRange(location: NSNotFound, length: 0))
            XCTAssertNil(AccessibleTextCapturePolicy.selection(selection, textLength: 20, required: true))
        }
    }

    func testReadableCaretDoesNotRequireAdvertisedSelectionSetter() {
        let caret = NSRange(location: 8, length: 0)
        XCTAssertEqual(AccessibleTextCapturePolicy.selection(caret, textLength: 8, required: true), caret)
        XCTAssertEqual(AccessibleTextCapturePolicy.selection(caret, textLength: 8, required: false), caret)
    }

    func testWritableOmniboxAndNativeInputsWithoutEditableAttributeAreAccepted() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: role, subrole: nil, enabled: true,
                editable: nil, valueWritable: true, selectedTextWritable: false), .editable)
            XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: role, subrole: nil, enabled: nil,
                editable: nil, valueWritable: false, selectedTextWritable: true), .editable)
        }
    }

    func testExplicitReadOnlyAndPasswordFieldsStayExcludedEvenWithWriteCapabilities() {
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXTextArea", subrole: nil, enabled: true,
            editable: false, valueWritable: true, selectedTextWritable: true), .readOnly)
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXTextField", subrole: "AXSecureTextField", enabled: true,
            editable: true, valueWritable: true, selectedTextWritable: true), .secure)
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXTextField", subrole: nil, enabled: false,
            editable: true, valueWritable: true, selectedTextWritable: true), .readOnly)
    }

    func testSelectableReadOnlyTextAndNonEditingExcelCellsAreExcluded() {
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXTextArea", subrole: nil, enabled: true,
            editable: nil, valueWritable: false, selectedTextWritable: false), .readOnly)
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXCell", subrole: nil, enabled: true,
            editable: nil, valueWritable: true, selectedTextWritable: false), .readOnly)
        XCTAssertEqual(AccessibleTextCapturePolicy.editability(role: "AXCell", subrole: nil, enabled: true,
            editable: true, valueWritable: false, selectedTextWritable: false), .editable)
    }
}
