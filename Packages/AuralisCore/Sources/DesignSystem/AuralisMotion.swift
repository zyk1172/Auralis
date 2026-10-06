// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftUI

/// Shared motion language for Apple-platform UI.
///
/// Keep motion short, spatially meaningful, and free of decorative bounce.
/// Callers should prefer the system's navigation/presentation transitions for
/// large structural changes and use these curves only for local state changes.
public enum AuralisMotion {
    public static func micro(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0)
    }

    public static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)
    }

    public static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.36, extraBounce: 0)
    }

    public static func emphasized(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0)
    }

    /// Section changes keep spatial motion out of the root shell. With Reduce
    /// Motion enabled a very short fade remains so content never flashes.
    public static func crossFade(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.10) : .easeInOut(duration: 0.20)
    }
}
