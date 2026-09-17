import Foundation

/// One recording as it lives in the output folder: the protocol and the
/// transcript at the top level, the audio and sidecars under `recordings/`,
/// all sharing the `YYYYMMDD_HHMM_<slug>_<jobid>` stem the pipeline names
/// every artifact with.
struct ProtocolEntry: Identifiable, Equatable {
    let stem: String
    let recordedAt: Date
    /// Protocol heading when there is one, else the stem's slug with the
    /// underscores turned back into spaces.
    let title: String
    let protocolURL: URL?
    let transcriptURL: URL?
    /// Everything under `recordings/` with this stem: WAVs plus the naming
    /// and segment sidecars, which are worthless once the audio is gone.
    let audioURLs: [URL]
    let audioBytes: Int64
    /// A job in the pipeline still refers to these files (transcribing, or
    /// waiting for speaker names), so removing them would pull the floor out
    /// from under it.
    let isBusy: Bool

    var id: String {
        stem
    }
}

/// What "delete" takes with it. Audio is where the space goes (three WAVs
/// per meeting, tens of MB each), the text is worth keeping for its own sake.
enum ProtocolRemovalScope {
    case everything
    case audioOnly
}

/// How files leave the folder. Production moves them to the Trash; tests
/// record what would have gone.
protocol FileRemoving {
    func remove(_ url: URL) throws
}

struct TrashFileRemover: FileRemoving {
    func remove(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Pure scan of the output folder into `ProtocolEntry` rows, newest first.
enum ProtocolLibrary {
    /// `YYYYMMDD_HHMM_<slug>_<8 hex>`; the slug may itself contain underscores.
    private static let stemPattern = #"^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})_(.+)_[0-9a-f]{8}$"#

    static func scan(outputDir: URL, busyStems: Set<String> = []) -> [ProtocolEntry] {
        let fm = FileManager.default
        let recordingsDir = outputDir.appendingPathComponent("recordings", isDirectory: true)
        var protocols: [String: URL] = [:]
        var transcripts: [String: URL] = [:]
        var audio: [String: [URL]] = [:]

        for url in files(in: outputDir) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard parse(stem: stem) != nil else { continue }
            switch url.pathExtension.lowercased() {
            case "md": protocols[stem] = url
            case "txt": transcripts[stem] = url
            default: break
            }
        }
        for url in files(in: recordingsDir) {
            guard let stem = audioStem(of: url) else { continue }
            audio[stem, default: []].append(url)
        }

        let stems = Set(protocols.keys).union(transcripts.keys).union(audio.keys)
        return stems.compactMap { stem -> ProtocolEntry? in
            guard let parsed = parse(stem: stem) else { return nil }
            let audioURLs = (audio[stem] ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let bytes = audioURLs.reduce(Int64(0)) { sum, url in
                sum + Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            }
            return ProtocolEntry(
                stem: stem,
                recordedAt: parsed.date,
                title: protocols[stem].flatMap(heading) ?? parsed.slug.replacingOccurrences(of: "_", with: " "),
                protocolURL: protocols[stem],
                transcriptURL: transcripts[stem],
                audioURLs: audioURLs,
                audioBytes: bytes,
                isBusy: busyStems.contains(stem),
            )
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    static func remove(_ entry: ProtocolEntry, scope: ProtocolRemovalScope, using remover: any FileRemoving) throws {
        var doomed = entry.audioURLs
        if scope == .everything {
            doomed += [entry.protocolURL, entry.transcriptURL].compactMap(\.self)
        }
        for url in doomed {
            try remover.remove(url)
        }
    }

    // MARK: - Helpers

    private static func files(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )) ?? []
    }

    /// `<stem>_<suffix>.<ext>` under `recordings/`: the stem is everything up
    /// to the job id, and the file must carry a suffix after it.
    private static func audioStem(of url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{8}_\d{4}_.+_[0-9a-f]{8})_[A-Za-z0-9]+$"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[range])
    }

    private static func parse(stem: String) -> (date: Date, slug: String)? {
        guard let regex = try? NSRegularExpression(pattern: stemPattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { return nil }
        func group(_ i: Int) -> String {
            Range(match.range(at: i), in: stem).map { String(stem[$0]) } ?? ""
        }
        var comps = DateComponents()
        comps.year = Int(group(1))
        comps.month = Int(group(2))
        comps.day = Int(group(3))
        comps.hour = Int(group(4))
        comps.minute = Int(group(5))
        guard let date = Calendar.current.date(from: comps) else { return nil }
        return (date, group(6))
    }

    /// The first `# ` heading of the protocol, minus the fixed
    /// "Meeting Protocol - " prefix the generator puts in front of the title.
    private static func heading(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.hasPrefix("# ") {
            var title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let range = title.range(of: "Meeting Protocol - ") { title.removeSubrange(range) }
            return title.isEmpty ? nil : title
        }
        return nil
    }
}
