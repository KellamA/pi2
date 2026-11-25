// A stand-in for the engine's `presented.file`: a page's files read from a folder, as the engine will read them from
// the copy it made. The manifest is made without following a symbolic link (one is left out, whatever it points to),
// and a file is read by walking its path one part at a time with O_NOFOLLOW, so that a link put in place after the
// manifest was made is refused too, and only if it is still exactly the size the manifest says.

import Foundation
import TranscriptKit

struct FolderFiles: PresentedFiles {
    let folder: URL

    /// The folder's regular files, symbolic links and anything else left out, with the entry to load first.
    func manifest(entry: String = "index.html") -> PresentedPage {
        var files: [PresentedFile] = []
        func walk(_ relative: String, depth: Int) {
            let base = relative.isEmpty ? folder.path : folder.path + "/" + relative
            guard depth < 8, let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return }
            for name in names.sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(folder.path + "/" + path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: files.append(PresentedFile(path: path, size: Int(info.st_size), mimeType: Self.type(of: name)))
                case S_IFDIR: walk(path, depth: depth + 1)
                default: continue
                }
            }
        }
        walk("", depth: 0)
        return PresentedPage(entry: entry, files: files)
    }

    func bytes(of file: PresentedFile) async throws -> Data {
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw Refused.path }
        var directory = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw Refused.path }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(directory)
            guard next >= 0 else { throw Refused.path }
            directory = next
        }
        let descriptor = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW)
        close(directory)
        guard descriptor >= 0 else { throw Refused.path }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) == file.size else { throw Refused.path }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: file.size + 1) ?? Data()
        guard data.count == file.size else { throw Refused.path }
        return data
    }

    enum Refused: Error { case path }

    static func type(of name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs": "application/javascript"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
