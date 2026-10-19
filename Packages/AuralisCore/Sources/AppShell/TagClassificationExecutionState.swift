// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// Independent execution grants. Expiration of a short lease must not cancel a foreground job,
/// real background audio, or a job that still owns BGProcessing time.
struct TagClassificationExecutionState {
    var isForeground = true
    var isAudioPlaying = false
    var hasShortTaskTime = false
    var hasProcessingTime = false
    var canContinue: Bool { isForeground || isAudioPlaying || hasShortTaskTime || hasProcessingTime }
}
