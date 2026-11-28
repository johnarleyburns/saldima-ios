// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PDFKit

/// Extracts a text-based PDF statement's full text, page by page, in page
/// order, using Apple's own `PDFKit` -- a first-party framework, no new
/// dependency, no license question. This is the only file in the import
/// feature that touches PDFKit; everything else (`ImportPdf.swift`'s
/// line-parsing heuristic) is plain Swift so it stays testable on Linux.
///
/// `nil` means PDFKit couldn't even open the data as a PDF at all. An
/// openable PDF with no extractable text (a scanned/image-only statement)
/// returns an empty string -- `parsePdfStatementText` turns that into the
/// "not supported" message rather than a crash or a fabricated row.
func extractPdfText(from data: Data) -> String? {
    guard let document = PDFDocument(data: data) else { return nil }
    var text = ""
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        text += page.string ?? ""
        text += "\n"
    }
    return text
}
