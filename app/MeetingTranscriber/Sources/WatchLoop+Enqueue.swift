import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The single funnel every finished recording passes through (auto, manual,
/// microphone-only, the quit path), split out of `WatchLoop.swift` to keep
/// that file under the length cap. It touches no private state of the loop.
extension WatchLoop {
    func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String] = [],
        calendarMayName: Bool = true,
    ) {
        let (title, participants, participantEmails) = calendarNamed(
            title: title, participants: participants, appName: appName,
            recording: recording, calendarMayName: calendarMayName,
        )

        if recordOnly() {
            do {
                try writeRecordOnlySidecar(
                    title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
                )
            } catch {
                reportRecordOnlyFailure(error)
            }
            return
        }

        let job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            participants: participants,
            participantEmails: participantEmails.isEmpty ? nil : participantEmails,
            meetingStartTime: recording.recordingStartDate,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title, privacy: .private)")
    }
}
