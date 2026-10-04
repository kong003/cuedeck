import Foundation

/// Converts files macOS can't play (MKV, AVI, WebM, ...) to ProRes 422 .mov
/// with every audio track kept as 24-bit PCM. Requires ffmpeg (Homebrew).
enum Converter {
    static var ffmpegPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                          "\(home)/.homebrew/bin/ffmpeg", "\(home)/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { ffmpegPath != nil }

    /// Where the converted file goes: next to the original if that folder is
    /// writable, otherwise ~/Movies/CueDeck.
    static func destination(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + " (CueDeck).mov"
        let folder = url.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path) {
            return folder.appendingPathComponent(name)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CueDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        return movies.appendingPathComponent(name)
    }

    static func convert(_ url: URL) async throws -> URL {
        guard let ffmpeg = ffmpegPath else {
            throw MediaError.build("ffmpeg is not installed. Install it with: brew install ffmpeg")
        }
        let dest = destination(for: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-i", url.path,
            "-map", "0:v:0?", "-map", "0:a?",
            "-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le",
            "-c:a", "pcm_s24le",
            dest.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        if status != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MediaError.build("Converting \(url.lastPathComponent) failed. \(text.suffix(300))")
        }
        return dest
    }
}
