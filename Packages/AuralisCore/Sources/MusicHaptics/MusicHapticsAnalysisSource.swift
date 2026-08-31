import Foundation

/// Opaque, upper-layer supplied input for haptics analysis.  MusicHaptics
/// consumes the source but never constructs an OpenSubsonic request and never
/// logs its URL.  The URL is intentionally kept out of diagnostics and cache
/// records; it only lives for the lifetime of an analysis session.
/// This is deliberately a runtime-only value.  Its URL contains the server's
/// authentication material, so it must never become part of a Codable plan or
/// checkpoint.
public struct MusicHapticsRemoteLookaheadSource: Hashable, Sendable {
    public let url: URL
    public let bitrate: Int
    public let format: String

    public init(url: URL, bitrate: Int = 96, format: String = "mp3") {
        self.url = url
        self.bitrate = max(1, bitrate)
        self.format = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum MusicHapticsAnalysisSource: Hashable, Sendable {
    case localFile(URL)
    case remoteLookahead(MusicHapticsRemoteLookaheadSource)
    /// An independent progressive HTTP stream used only when the server cannot
    /// provide a low-bitrate sidecar. It is never installed on AVPlayer.
    case remoteProgressive(URL)
    case realtimeTap

    public var mode: MusicHapticsAnalysisMode {
        switch self {
        case .localFile: .local
        case .remoteLookahead: .remoteLookahead
        case .remoteProgressive: .remoteProgressive
        case .realtimeTap: .realtimeTap
        }
    }
}

public enum MusicHapticsAnalysisMode: String, Codable, Hashable, Sendable {
    case local
    case remoteLookahead
    case remoteProgressive
    case realtimeTap
}

/// Privacy-safe reasons emitted when the analysis source chain cannot produce
/// haptic events. These values are intentionally stable so diagnostics and
/// device logs can be searched without exposing a URL or server credential.
public enum MusicHapticsAnalysisDiagnostic: String, Codable, Hashable, Sendable {
    case remoteSidecarURLUnavailable = "remote_sidecar_url_unavailable"
    case remoteDownloadFailed = "remote_download_failed"
    case loadTracksFailed = "load_tracks_failed"
    case noAudioTrack = "no_audio_track"
    case readerInitFailed = "reader_init_failed"
    case readerOutputConfigurationFailed = "reader_output_configuration_failed"
    case readerStartFailed = "reader_start_failed"
    case sampleReadFailed = "sample_read_failed"
    case sampleDataUnavailable = "sample_data_unavailable"
    case remoteDecoderFailed = "remote_decoder_failed"
    case remoteProgressiveFallback = "remote_progressive_fallback"
    case realtimeFallbackForbidden = "realtime_fallback_forbidden"
    case noHapticEventSource = "no_haptic_event_source"
}

/// A decoder failure that is safe to expose in diagnostics. The source URL,
/// query items, credentials and localized error text are intentionally omitted;
/// the NSError domain and code are enough to distinguish the AVFoundation
/// failure stage on a real device.
public struct MusicHapticsDecoderFailure: Hashable, Sendable {
    public let diagnostic: MusicHapticsAnalysisDiagnostic
    public let errorDomain: String
    public let errorCode: Int

    public init(
        diagnostic: MusicHapticsAnalysisDiagnostic,
        errorDomain: String = "AuralisMusicHaptics",
        errorCode: Int = 0
    ) {
        self.diagnostic = diagnostic
        self.errorDomain = Self.sanitizedDomain(errorDomain)
        self.errorCode = errorCode
    }

    public var summary: String {
        let reason = diagnostic.rawValue
        return "\(reason) domain=\(errorDomain) code=\(errorCode)"
    }

    private static func sanitizedDomain(_ domain: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = domain.unicodeScalars.filter { allowed.contains($0) }
        let value = String(String.UnicodeScalarView(sanitized))
        return String(value.prefix(64)).isEmpty ? "unknown" : String(value.prefix(64))
    }
}

/// The AppShell/connector layer implements this protocol.  It may use an
/// existing local file or create a short-lived authenticated low-bitrate URL,
/// but MusicHaptics itself remains independent of server credentials and SDKs.
public protocol MusicHapticsAnalysisSourceProvider: Sendable {
    func source(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?
    ) async -> MusicHapticsAnalysisSource?

    /// Called only after an independent remote analysis source fails. The
    /// provider may refresh a short-lived sidecar URL and then offer the
    /// original progressive URL as a final independent decoder source.
    func fallbackSources(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?,
        after failedSource: MusicHapticsAnalysisSource
    ) async -> [MusicHapticsAnalysisSource]
}

public extension MusicHapticsAnalysisSourceProvider {
    func fallbackSources(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?,
        after failedSource: MusicHapticsAnalysisSource
    ) async -> [MusicHapticsAnalysisSource] {
        []
    }
}
