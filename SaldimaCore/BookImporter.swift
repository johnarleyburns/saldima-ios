// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum BookImporterError: Error, Equatable, Sendable {
    case alreadyExists
    case cannotCreate
    case emptySnapshot
    case sqlite(String)
}

/// Materializes a format-neutral `BookSnapshot` (read from a desktop-authored
/// GnuCash file in either dialect, via `XMLBookReader` or `SQLiteBookReader`)
/// as a fresh standalone `.gnucash` XML working copy, so any supported
/// import source becomes a real, editable local book through the exact same
/// `BookStore` as one created on-device. SQLite stays an import/export
/// boundary only; the working copy this produces is XML, edited like any
/// other.
public enum BookImporter {
    public static func materialize(
        _ snapshot: BookSnapshot,
        at url: URL,
        ids: any IDGenerator,
        overwrite: Bool = false
    ) throws {
        guard !snapshot.accounts.isEmpty else { throw BookImporterError.emptySnapshot }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard overwrite else { throw BookImporterError.alreadyExists }
            try fileManager.removeItem(at: url)
        }

        let document = XMLBookDocument.build(from: snapshot, templateRootGuid: ids.guid(), ids: ids)
        do {
            try Gzip.deflate(document.serialize()).write(to: url, options: .atomic)
        } catch {
            throw BookImporterError.cannotCreate
        }
    }
}
