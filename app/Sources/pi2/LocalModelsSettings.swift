import AppKit
import BrowserKit
import SwiftUI

// Models on this Mac (#292 of #173), in Settings › Providers: getting the Strata engine and a model pack, with their
// licences shown first, progress, pause, resume and cancel; choosing where models are kept; setting a model's context
// size and the rest; and trying it. The engine does all of it (engine/src/localmodels.ts) and sends what stands as its
// `local` event, with each download's progress as `local.progress`; this only shows it. See docs/local-models.md.

/// What the engine's `local` event says.
struct LocalStatus: Decodable {
    struct Platform: Decodable {
        let supported: Bool
        let why: String?
        let memoryGB: Double
        /// What Metal lets one program keep in memory, in GB.
        let limitGB: Double
    }
    struct Licence: Decodable, Hashable {
        let name: String
        let url: String
        let summary: String
        /// A part of it the person must read before agreeing, in its own words, shown in full where they agree.
        let quote: String?
    }
    struct InstalledEngine: Decodable { let version: String }
    struct Engine: Decodable {
        struct Pinned: Decodable { let version: String; let controlVersion: String; let size: Double; let licences: [Licence] }
        let installed: InstalledEngine?
        let pinned: Pinned
        let update: Bool
    }
    struct Pack: Decodable, Identifiable {
        let id: String
        let pack: String
        let provider: String
        let note: String
        let needsGB: Double
        let size: Double
        /// Disk space Strata's setup takes when it prepares the model, as well.
        let prepareSize: Double
        let fit: String
        let fitNote: String
        let recommended: Bool
        let licences: [Licence]
        let unavailable: String?
        let installed: Bool
    }
    struct CatalogModel: Decodable, Identifiable { let id: String; let name: String; let packs: [Pack] }
    struct Options: Decodable { let vision: Bool; let visionFile: String?; let parallel: Int }
    struct Model: Decodable, Identifiable {
        let id: String
        let name: String
        let contextSize: Int
        let options: Options
        let needsGB: Double?
        /// Prepared for Strata, so it can run; false while it is being prepared again (after an update of Strata).
        let prepared: Bool?
    }
    struct Download: Decodable, Identifiable {
        struct Retry: Decodable { let reason: String }
        /// While Strata's setup prepares the model: the step it is at (of 7), what it says it is doing, and how far.
        struct Prepare: Decodable { let step: Int?; let stage: String?; let fraction: Double? }
        let id: String
        let kind: String
        let name: String
        /// "running", "paused", "failed", or "waiting" (downloaded and checked, waiting for the engine to be prepared).
        let state: String
        let phase: String?
        let error: String?
        let received: Double
        let total: Double
        let retry: Retry?
        /// "download", or "prepare" once its files are all here.
        let stage: String?
        /// A model set up before, being prepared again: it cannot be cancelled, only removed.
        let again: Bool?
        let prepare: Prepare?
        /// The person's folder its files are taken from, where they match.
        let from: String?
        /// What Strata's setup printed while preparing it.
        let log: String?
    }
    /// A model loaded or loading, as the running part of pi² says (the same as Activity's).
    struct Running: Decodable { let id: String; let status: String; let startedAt: Double; let stage: String? }
    struct Folder: Decodable { let path: String; let isDefault: Bool; let free: Double? }
    struct Context: Decodable { let sizes: [Int]; let `default`: Int; let measured: Int; let gbPerToken: Double }
    /// Requests at once (#605): the default for a new model, the most offered, the memory each takes per token of context
    /// once there is more than one, and whether the engine set up runs several (one older than 0.1.62 runs one).
    struct Requests: Decodable { let `default`: Int; let most: Int; let slotGBPerToken: Double; let several: Bool }

    let platform: Platform
    let engine: Engine
    let catalog: [CatalogModel]
    let models: [Model]
    let downloads: [Download]
    let folder: Folder
    let context: Context
    let requests: Requests?
    let running: [Running]?

    init?(_ value: JSONValue?) {
        guard let value, let data = try? JSONEncoder().encode(value), let decoded = try? JSONDecoder().decode(LocalStatus.self, from: data) else { return nil }
        self = decoded
    }

    var engineDownload: Download? { downloads.first { $0.kind == "engine" } }
    var modelDownloads: [Download] { downloads.filter { $0.kind == "model" } }

    /// About how much memory a model takes with this context and this many requests at once, in GB.
    func memoryGB(needs: Double, context size: Int, parallel: Int) -> Double {
        // With more than one at once, Strata keeps a session of its own for each request as well (#605).
        let several = parallel > 1 ? (requests?.slotGBPerToken ?? context.gbPerToken) * Double(size) * Double(parallel) : 0
        return needs + context.gbPerToken * Double(size) + several
    }

    /// What each request at once beyond the first takes in memory with this context, in GB.
    func slotGB(context size: Int) -> Double {
        (requests?.slotGBPerToken ?? context.gbPerToken) * Double(size)
    }
}

extension JSONValue {
    /// This `local` event with one download's progress, from a `local.progress` event, in place of what it said.
    func replacingDownload(_ download: JSONValue) -> JSONValue {
        guard case .object(var status) = self, case .array(let downloads)? = status["downloads"], let id = download["id"] else { return self }
        status["downloads"] = .array(downloads.map { $0["id"] == id ? download : $0 })
        return .object(status)
    }
}

enum LocalFormat {
    static func size(_ bytes: Double) -> String {
        if bytes < 1e9 { return String(format: "%.1f MB", bytes / 1e6) }
        if bytes >= 1e12 { return String(format: "%.1f TB", bytes / 1e12) }
        return String(format: bytes < 10e9 ? "%.1f GB" : "%.0f GB", bytes / 1e9)
    }
    static func gb(_ value: Double) -> String { String(format: value < 10 ? "%.1f GB" : "%.0f GB", value) }
    static func tokens(_ count: Int) -> String { "\(count / 1024)K tokens" }
}

/// The section in Settings › Providers.
struct LocalModelsSection: View {
    let engine: EngineClient
    @State private var gettingEngine = false
    @State private var gettingModel = false
    @State private var configuring: LocalStatus.Model?
    @State private var problem: String?
    /// What trying each model gave: its answer, or why it could not.
    @State private var trials: [String: (text: String, failed: Bool)] = [:]
    @State private var trying: Set<String> = []

    private var status: LocalStatus? { LocalStatus(engine.extras["local"]) }

    var body: some View {
        Section {
            if let status {
                if !status.platform.supported, let why = status.platform.why {
                    Text(why).foregroundStyle(.secondary)
                } else {
                    engineRow(status)
                    ForEach(status.models) { model in modelRow(model, status) }
                    ForEach(status.modelDownloads) { download in DownloadRow(download: download, act: act) }
                    HStack {
                        Button("Get a Model…") { gettingModel = true }
                        Spacer()
                        Text("Models are kept in \(status.folder.isDefault ? "pi²'s own folder" : (status.folder.path as NSString).abbreviatingWithTildeInPath)\(status.folder.free.map { " · \(LocalFormat.size($0)) free" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { chooseFolder() }
                        if !status.folder.isDefault { Button("Use pi²'s Folder") { act("local.model.folder", ["path": NSNull()]) } }
                    }
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(Theme.bad) }
            } else {
                Text("Waiting for the engine…").foregroundStyle(.secondary)
            }
        } header: {
            Text("On this Mac")
        } footer: {
            Text("Run a model on this Mac with the Strata engine, without sending anything to a provider. pi² downloads a version of Strata and of each model that it knows the checksums of, and runs nothing that does not match. Models are tens of gigabytes: they are kept where neither pi²'s backup nor Time Machine copies them, and a download carries on after pi² quits or the network drops. A model you set up here is offered in the model menus under On this Mac.").formFooter()
        }
        .sheet(isPresented: $gettingEngine) {
            if let status { EngineSheet(status: status, act: act) }
        }
        .sheet(isPresented: $gettingModel) {
            if let status { ModelPackSheet(status: status, act: act) }
        }
        .sheet(item: $configuring) { model in
            if let status { ConfigureLocalModelSheet(model: model, status: status, act: act) }
        }
        #if PI2_DEVELOPMENT
        .task {
            // A development build opened with `settings:providers#local=<sheet>`; the status arrives a moment later.
            guard let wanted = SettingsLaunch.takeLocalSheet() else { return }
            for _ in 0..<600 {
                if let status {
                    if wanted == "engine" {
                        gettingEngine = true
                        return
                    } else if wanted == "model" {
                        gettingModel = true
                        return
                    } else if let model = status.models.first(where: { "configure:\($0.id)" == wanted }) {
                        configuring = model
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
    }

    @ViewBuilder
    private func engineRow(_ status: LocalStatus) -> some View {
        if let download = status.engineDownload {
            DownloadRow(download: download, act: act)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strata engine")
                    Group {
                        if let installed = status.engine.installed {
                            Text(!status.engine.update ? "Version \(installed.version) · ready"
                                : installed.version == status.engine.pinned.version ? "Version \(installed.version) · set up by an earlier pi²: update it to run models"
                                : "Version \(installed.version) · version \(status.engine.pinned.version) is available")
                        } else {
                            Text("Not downloaded · version \(status.engine.pinned.version), \(LocalFormat.size(status.engine.pinned.size))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.engine.installed == nil {
                    Button("Get Strata…") { gettingEngine = true }
                } else {
                    if status.engine.update { Button("Update…") { gettingEngine = true } }
                    Button("Remove", role: .destructive) { act("local.engine.remove", [:]) }
                        .help("Delete the Strata engine from this Mac. Models stay; get Strata again to run them.")
                }
            }
        }
    }

    private func modelRow(_ model: LocalStatus.Model, _ status: LocalStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    let memory = model.needsGB.map { status.memoryGB(needs: $0, context: model.contextSize, parallel: model.options.parallel) }
                    Text("\(model.prepared == false ? "Being prepared for Strata · " : "")Context \(LocalFormat.tokens(model.contextSize))\(model.options.visionFile != nil ? (model.options.vision ? " · reads pictures" : " · pictures off") : "")\(model.options.parallel > 1 ? " · \(model.options.parallel) requests at once" : "")\(memory.map { " · about \(LocalFormat.gb($0)) of memory" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if trying.contains(model.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Try It") { tryModel(model) }
                        .disabled(status.engine.installed == nil || model.prepared == false)
                        .help(status.engine.installed == nil ? "Get the Strata engine first" : model.prepared == false ? "It is being prepared for Strata; it can be tried once that is done" : "Start the model and send it one short message")
                }
                Button("Configure…") { configuring = model }
                Button("Remove", role: .destructive) { act("local.model.remove", ["id": model.id]) }
                    .help("Delete this model's files from this Mac")
            }
            if trying.contains(model.id) {
                TryingLine(running: status.running?.first { $0.id == model.id })
            }
            if let trial = trials[model.id] {
                Text(trial.failed ? trial.text : "It answered: “\(trial.text)”")
                    .font(.callout).foregroundStyle(trial.failed ? Theme.bad : Theme.ok)
                    .textSelection(.enabled)
            }
        }
    }

    /// Starts the model with the part of pi² that runs it (#291), then sends it one message.
    private func tryModel(_ model: LocalStatus.Model) {
        trying.insert(model.id)
        trials[model.id] = nil
        Task {
            defer { trying.remove(model.id) }
            do {
                do {
                    try await engine.call("local.start", ["id": model.id])
                } catch let error as EngineError where error.message.hasPrefix("Unknown method") {
                    trials[model.id] = ("Trying it needs the part of pi² that starts models on this Mac, which this version does not have yet.", true)
                    return
                }
                let answer = try await engine.call("local.model.try", ["id": model.id])
                trials[model.id] = (answer["text"]?.stringValue ?? "", false)
            } catch {
                trials[model.id] = (error.localizedDescription, true)
            }
        }
    }

    private func chooseFolder() {
        guard let url = FilePanels.open("models-folder", selecting: .folders, configure: { panel in
            panel.canCreateDirectories = true
            panel.prompt = "Keep Models Here"
            panel.message = "Models are tens of gigabytes. Choose a folder on a disk with room for them; models already set up stay where they are."
        })?.first else { return }
        act("local.model.folder", ["path": url.path])
    }

    /// Sends a request; what it changes comes back in the `local` event. Its error, if any, is shown under the section.
    private func act(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                try await engine.call(method, params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    fileprivate typealias Act = (String, [String: Any]) -> Void
}

/// While Try It starts a model: what the engine says it is doing and for how long, and what to expect of a first start.
private struct TryingLine: View {
    let running: LocalStatus.Running?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(at: context.date)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(at now: Date) -> String {
        guard let running, running.status == "starting" else { return running?.status == "ready" ? "Loaded. Asking it a first question…" : "Starting it…" }
        let seconds = max(0, Int(now.timeIntervalSince1970 - running.startedAt / 1000))
        let elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "Starting it on this Mac (\(elapsed))\(running.stage.map { ": \($0)" } ?? ""). The first start after setting it up can take about three minutes, while macOS prepares Strata for this Mac's graphics, and the Mac may be slow meanwhile; later starts take about 20 seconds."
    }
}

/// A download under way, paused or stopped, or a model being prepared for Strata, with what can be done about it.
private struct DownloadRow: View {
    let download: LocalStatus.Download
    let act: LocalModelsSection.Act

    private var preparing: Bool { download.stage == "prepare" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(download.name)
                Spacer()
                if download.state == "failed" || download.stage == "prepare", download.error != nil, let log = download.log, FileManager.default.fileExists(atPath: log) {
                    Button("Show Log") { LocalModels.showLog(log) }
                        .help("Open what Strata's setup printed: \(log)")
                }
                if download.state == "running" {
                    Button("Pause") { act("local.download.pause", ["id": download.id]) }
                } else if download.state != "waiting" {
                    Button(download.state == "failed" ? "Try Again" : "Resume") { act("local.download.resume", ["id": download.id]) }
                }
                if download.again != true {
                    Button("Cancel", role: .destructive) { act("local.download.cancel", ["id": download.id]) }
                        .help(preparing ? "Stop, and delete the model's files and what preparing it made" : "Stop the download and delete what it downloaded so far")
                }
            }
            if preparing, download.state == "running" {
                if let fraction = download.prepare?.fraction {
                    ProgressView(value: fraction)
                } else if let step = download.prepare?.step {
                    ProgressView(value: Double(step - 1) / 7)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else {
                ProgressView(value: download.total > 0 ? min(download.received / download.total, 1) : 0)
            }
            Text(caption).font(.caption).foregroundStyle(download.error != nil && download.state != "waiting" ? Theme.bad : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var caption: String {
        let amount = "\(LocalFormat.size(download.received)) of \(LocalFormat.size(download.total))"
        if let error = download.error { return download.received > 0 && !preparing ? "\(amount). \(error)" : error }
        if preparing {
            if download.state == "paused" { return "Downloaded and checked. Preparing it for Strata is paused; Resume carries on from where it stopped." }
            let doing = download.prepare?.stage.map { ": \($0)" } ?? ""
            let step = download.prepare?.step.map { " (step \($0) of 7)" } ?? ""
            return "\(download.again == true ? "Preparing it again for the Strata installed now" : "Downloaded and checked. Preparing it for Strata")\(step)\(doing). This is done once, and takes a few minutes; Strata fetches 5.2 GB more from Hugging Face for it unless it has them already."
        }
        if download.state == "paused" { return "Paused at \(amount)" }
        let mine = download.from.map { " from \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        switch download.phase {
        case "checking": return download.from == nil ? "Checking what was already downloaded (\(amount))…" : "Checking the files taken\(mine) (\(amount))…"
        case "copying": return "Copying the files already on this Mac\(mine), and checking them (\(amount))…"
        case "unpacking": return "Checked; setting it up…"
        case "waiting": return "\(amount). \(download.retry?.reason ?? "") Trying again shortly."
        default: return amount
        }
    }
}

/// A licence, as shown before the download it belongs to.
private struct LicenceView: View {
    let licence: LocalStatus.Licence
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(licence.name).bold()
                if let url = URL(string: licence.url) { Link("Read it", destination: url) }
            }
            Text(licence.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let quote = licence.quote {
                ScrollView {
                    Text(quote)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                }
                .frame(minHeight: 90, maxHeight: 170)
                .background(Theme.line2.opacity(0.35), in: .rect(cornerRadius: 6))
                .accessibilityLabel("From the \(licence.name)")
            }
        }
    }
}

/// Getting or updating the engine: what it is, its size and its licence, before anything is downloaded.
private struct EngineSheet: View {
    let status: LocalStatus
    let act: LocalModelsSection.Act
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pinned = status.engine.pinned
        VStack(alignment: .leading, spacing: 14) {
            Text(status.engine.installed == nil ? "Get the Strata engine" : "Update the Strata engine").font(.title3).bold()
            Text("Strata is the program that runs a model on this Mac. pi² downloads engine \(pinned.version) and the server that comes with it, \(pinned.controlVersion) (\(LocalFormat.size(pinned.size)) in all), from Strata's releases on GitHub, checks each against the checksum pi² has for that version, and sets them up only if they match. A newer version comes with a pi² update, once it has been checked.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Licence").sectionLabel()
            ForEach(pinned.licences, id: \.self) { LicenceView(licence: $0) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Agree and Download") {
                    act("local.engine.install", ["accept": true])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Choosing a model pack: each with its size, the memory it needs, what is lost and whether it fits this Mac, and the
/// licences of the one chosen, before anything is downloaded.
private struct ModelPackSheet: View {
    let status: LocalStatus
    let act: LocalModelsSection.Act
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: String?

    private var packs: [(model: LocalStatus.CatalogModel, pack: LocalStatus.Pack)] {
        status.catalog.flatMap { model in model.packs.map { (model, $0) } }
    }

    var body: some View {
        let selected = packs.first { $0.pack.id == chosen }
        VStack(alignment: .leading, spacing: 12) {
            Text("Get a model").font(.title3).bold()
            Text("This Mac has \(Int(status.platform.memoryGB)) GB of memory. A model has to stay in memory while it runs to be quick, so choose one that fits; pi² recommends one.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(status.catalog) { model in
                        Text(model.name).sectionLabel()
                        ForEach(model.packs) { pack in packRow(pack) }
                    }
                }
            }
            .frame(maxHeight: 240)
            if let selected {
                Divider()
                Text("Licences of \(selected.model.name) \(selected.pack.pack)").sectionLabel()
                ForEach(selected.pack.licences, id: \.self) { LicenceView(licence: $0) }
                Text("It goes in \(status.folder.isDefault ? "pi²'s own folder for models" : (status.folder.path as NSString).abbreviatingWithTildeInPath), which has \(status.folder.free.map(LocalFormat.size) ?? "an unknown amount") free.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Agree and Use Files on This Mac…") {
                    guard let chosen, let folder = chooseFiles() else { return }
                    act("local.model.install", ["pack": chosen, "accept": true, "from": folder])
                    dismiss()
                }
                .disabled(selected == nil)
                .help("You already have this pack's files, from Strata or another download: choose the folder that holds them, or one above it. Those whose checksums match are used instead of being downloaded again.")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Agree and Download") {
                    guard let chosen else { return }
                    act("local.model.install", ["pack": chosen, "accept": true])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            chosen = packs.first { $0.pack.recommended && !$0.pack.installed }?.pack.id
        }
    }

    /// The folder of the person's own copy of the pack's files.
    private func chooseFiles() -> String? {
        FilePanels.open("local-model-files", selecting: .folders) { panel in
            panel.prompt = "Use These Files"
            panel.message = "Choose the folder that holds the model's files (the .gguf files), or a folder above it, such as Strata's own data folder. pi² checks each file's checksum before it uses it, and downloads only what is missing or does not match."
        }?.first?.path
    }

    private func packRow(_ pack: LocalStatus.Pack) -> some View {
        let usable = pack.unavailable == nil && !pack.installed && !status.downloads.contains { $0.id == pack.id }
        return Button {
            if usable { chosen = pack.id }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chosen == pack.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(usable ? Theme.acc : Theme.tx3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pack.pack).bold()
                        Text(pack.provider).foregroundStyle(.secondary)
                        if pack.recommended { Text("Recommended").font(.caption).foregroundStyle(Theme.ok) }
                        if pack.installed { Text("Set up").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("\(LocalFormat.size(pack.size)) to download\(pack.prepareSize > 0 ? ", and \(LocalFormat.size(pack.prepareSize)) more as it is prepared" : "") · needs about \(LocalFormat.gb(pack.needsGB)) of memory")
                        .font(.callout)
                    Text(pack.note).font(.callout).foregroundStyle(.secondary)
                    Text(pack.unavailable ?? pack.fitNote).font(.callout)
                        .foregroundStyle(pack.unavailable != nil ? Theme.tx3 : pack.fit == "fits" ? Theme.ok : pack.fit == "tight" ? Theme.warn : Theme.bad)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityAddTraits(chosen == pack.id ? .isSelected : [])
    }
}

/// A model's settings: its context size, with what each costs in memory, pictures, and requests at once.
private struct ConfigureLocalModelSheet: View {
    let model: LocalStatus.Model
    let status: LocalStatus
    let act: LocalModelsSection.Act
    @Environment(\.dismiss) private var dismiss
    @State private var context = 32_768
    @State private var vision = true
    @State private var parallel = 1

    private func memory(_ size: Int) -> Double? {
        model.needsGB.map { status.memoryGB(needs: $0, context: size, parallel: parallel) }
    }

    var body: some View {
        let total = memory(context)
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name).font(.title3).bold()
            Picker("Context size", selection: $context) {
                ForEach(status.context.sizes, id: \.self) { size in
                    Text("\(LocalFormat.tokens(size))\(memory(size).map { " · about \(LocalFormat.gb($0))" } ?? "")").tag(size)
                }
            }
            Text("How much of a conversation the model reads at once. Each step up takes more memory; pi² summarises a conversation that grows past it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let total, total > status.platform.limitGB {
                Text("This needs about \(LocalFormat.gb(total)), more than the \(LocalFormat.gb(status.platform.limitGB)) this Mac lets one program keep in memory: the model would read from the SSD and slow down a great deal, or not start. Choose a smaller context.")
                    .font(.callout).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
            } else if context > status.context.measured {
                Text("Strata has not measured contexts above \(LocalFormat.tokens(status.context.measured)) on a Mac: it may be slow, or less accurate far back in a long conversation.")
                    .font(.callout).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if model.options.visionFile != nil {
                Toggle("Read pictures", isOn: $vision)
                Text("The picture reader takes about 1 GB more. Without it, the model is not sent pictures.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Stepper("Requests at once: \(parallel)", value: $parallel, in: 1...(status.requests?.most ?? 4))
            Text("How many conversations the model answers at the same moment. With several, an agent whose tool has finished goes on within seconds instead of waiting for the others' whole turns. Together they write about as fast as one alone, since the Mac's engine takes them in turn, so each writes more slowly. With more than one, each keeps about \(LocalFormat.gb(status.slotGB(context: context))) more in memory at this context.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if status.requests?.several == false {
                Text("The Strata engine set up on this Mac answers one request at a time whatever this says: with more, it stopped itself when two answers were written side by side for a minute. Update Strata in Settings › Providers › On this Mac to run several.")
                    .font(.callout).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            Text("A change counts from the next time the model starts.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Defaults") {
                    context = status.context.default
                    vision = model.options.visionFile != nil
                    parallel = status.requests?.default ?? 4
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    act("local.model.configure", ["id": model.id, "contextSize": context, "options": ["vision": vision, "parallel": parallel]])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            context = model.contextSize
            vision = model.options.vision
            parallel = model.options.parallel
        }
    }
}
