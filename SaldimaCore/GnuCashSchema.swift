// SPDX-License-Identifier: AGPL-3.0-only

/// Release-level GnuCash schema gate. The per-table `versions` check arrives
/// with the introspected schema; this refuses whole release lines we have never
/// tested. Mirrors `packages/gnucash/src/versions.ts` on the web track.
public enum GnuCashSchema {
    public static func supports(major: Int, minor: Int) -> Bool {
        guard major >= 0, minor >= 0 else { return false }
        if major == 4 { return minor == 14 }
        if major == 5 { return minor <= 99 }
        return false
    }
}
