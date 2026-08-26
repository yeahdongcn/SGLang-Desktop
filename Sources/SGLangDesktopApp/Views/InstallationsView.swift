import SGLangDesktopCore
import SwiftUI
import UniformTypeIdentifiers

struct InstallationsView: View {
    @EnvironmentObject private var model: DesktopViewModel
    @State private var isImportingManifest = false
    @State private var isImportingLocalCLI = false

    var body: some View {
        Group {
            if model.installations.isEmpty {
                ContentUnavailableView {
                    Label("No runtimes installed", systemImage: "shippingbox")
                } description: {
                    Text(
                        "Install a signed runtime package, or adopt an existing developer runtime using its manifest."
                    )
                } actions: {
                    Button("Adopt Local Runtime Manifest…") {
                        isImportingManifest = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Use Local Development CLI…") {
                        isImportingLocalCLI = true
                    }
                }
            } else {
                List(model.installations) { installation in
                    RuntimeRow(installation: installation)
                }
            }
        }
        .navigationTitle("Installations")
        .toolbar {
            Menu {
                Button("Adopt Local Runtime Manifest…") {
                    isImportingManifest = true
                }
                Button("Use Local Development CLI…") {
                    isImportingLocalCLI = true
                }
            } label: {
                Label("Add Runtime", systemImage: "plus")
            }
        }
        .fileImporter(
            isPresented: $isImportingManifest,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let manifestURL = urls.first else { return }
            let hasAccess = manifestURL.startAccessingSecurityScopedResource()
            Task {
                await model.adoptRuntime(manifestURL: manifestURL)
                if hasAccess { manifestURL.stopAccessingSecurityScopedResource() }
            }
        }
        .fileImporter(
            isPresented: $isImportingLocalCLI,
            allowedContentTypes: [.unixExecutable, .item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let executableURL = urls.first else { return }
            let hasAccess = executableURL.startAccessingSecurityScopedResource()
            Task {
                await model.adoptLocalExecutable(executableURL)
                if hasAccess { executableURL.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

private struct RuntimeRow: View {
    @EnvironmentObject private var model: DesktopViewModel
    let installation: RuntimeInstallation

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: installation.manifest.engine == .sglang ? "text.bubble" : "waveform")
                .font(.title2)
                .foregroundStyle(installation.isActive ? .green : .secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(installation.manifest.displayName).font(.headline)
                    if installation.isActive {
                        Text("ACTIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    }
                }
                Text(
                    "\(installation.manifest.engine.displayName) · \(installation.manifest.version)"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(installation.rootDirectory.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if installation.manifest.channel == .local {
                    Text("Local development runtime · dependencies are managed by your checkout")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if !installation.isActive {
                Button("Make Active") {
                    Task { await model.activate(installation) }
                }
            }
        }
        .padding(.vertical, 7)
    }
}
