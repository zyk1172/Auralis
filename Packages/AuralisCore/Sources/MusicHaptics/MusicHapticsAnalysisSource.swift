import Foundation

/// The input used by the independent Music Haptics decoder.
///
/// A remote source is the same original-quality URL selected for playback. It
/// is opened by a second, read-only incremental decoder and is never assigned
/// to, seeked, or otherwise used to mutate the AVPlayerItem. Keeping this type
/// free of bitrate/format fields makes a server-side transcode impossible to
/// request accidentally.
public enum MusicHapticsAnalysisSource: Hashable, Sendable {
    case localFile(URL)
    case remoteOriginal(URL)
    case realtimeTap

    public var mode: MusicHapticsAnalysisMode {
        switch self {
        case .localFile: .local
        case .remoteOriginal: .remoteOriginal
        case .realtimeTap: .realtimeTap
        }
    }
}

public enum MusicHapticsAnalysisMode: String, Codable, Hashable, Sendable {
    case local
    case remoteOriginal
    case realtimeTap
}

/// Privacy-safe reasons emitted when the analysis source chain cannot produce
/// haptic events. Values are stable for device diagnostics and contain no URL,
/// token, credential, or localized server response.
public enum MusicHapticsAnalysisDiagnostic: String, Codable, Hashable, Sendable {
    case remoteOriginalURLUnavailable = "remote_original_url_unavailable"
    case remoteOriginalRefresh = "remote_original_refresh"
    case remoteHTTPResponseFailed = "remote_http_response_failed"
    case streamOpenFailed = "stream_open_failed"
    case streamParseFailed = "stream_parse_failed"
    case streamPropertyFailed = "stream_property_failed"
    case converterInitFailed = "converter_init_failed"
    case converterFailed = "converter_failed"
    case noAudioFormat = "no_audio_format"
    case noAudioPacket = "no_audio_packet"
    case sampleDataUnavailable = "sample_data_unavailable"
    case remoteDecoderFailed = "remote_decoder_failed"
    case realtimeFallbackForbidden = "realtime_fallback_forbidden"
    case noHapticEventSource = "no_haptic_event_source"
    case pcmStarvation = "pcm_starvation"
}

/// A decoder failure that is safe to expose in diagnostics. The source URL,
/// query items, credentials and localized error text are intentionally omitted;
/// the stage plus NSError domain/code identify the failing boundary on a real
/// device without leaking authentication material.
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
        "\(diagnostic.rawValue) domain=\(errorDomain) code=\(errorCode)"
    }

    private static func sanitizedDomain(_ domain: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = domain.unicodeScalars.filter { allowed.contains($0) }
        let value = String(String.UnicodeScalarView(sanitized))
        return String(value.prefix(64)).isEmpty ? "unknown" : String(value.prefix(64))
    }
}

/// The AppShell/connector layer supplies an already authenticated original
/// stream URL. MusicHaptics never constructs a server request or owns the
/// credential-bearing connector.
public protocol MusicHapticsAnalysisSourceProvider: Sendable {
    func source(
        for identity: MusicHapticsIdentity,
        playbackURL: URL?
    ) async -> MusicHapticsAnalysisSource?

    /// Refreshes the original stream URL after a bounded decoder/network
    /// failure. A refresh is a retry of the same encoding, never a sidecar or
    /// transcoding fallback.
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
