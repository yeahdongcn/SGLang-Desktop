import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public enum DiagnosticStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

public enum DiagnosticRepairAction: String, Codable, Sendable {
    case redetect
    case chooseFreePort
    case openSoftwareUpdate
    case openInstallations
    case openModels
}

public struct DiagnosticItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: DiagnosticStatus
    public let blocksReadiness: Bool
    public let repairAction: DiagnosticRepairAction?
    public let repairLabel: String?

    public init(
        id: String,
        title: String,
        detail: String,
        status: DiagnosticStatus,
        blocksReadiness: Bool = true,
        repairAction: DiagnosticRepairAction? = nil,
        repairLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.blocksReadiness = blocksReadiness
        self.repairAction = repairAction
        self.repairLabel = repairLabel
    }
}

public struct DiagnosticReport: Equatable, Sendable {
    public let items: [DiagnosticItem]

    public var isReady: Bool {
        !items.contains(where: { $0.status == .failed && $0.blocksReadiness })
    }

    public init(items: [DiagnosticItem]) {
        self.items = items
    }
}

public struct AppleSystemDiagnostics: Sendable {
    public init() {}

    public func run(
        host: HostSystemProfile,
        installations: [RuntimeInstallation],
        models: [ManagedModel],
        paths: AppPaths,
        port: UInt16,
        activePortIsExpected: Bool = false
    ) async -> DiagnosticReport {
        var items: [DiagnosticItem] = []

        items.append(platformCheck(host))
        items.append(memoryCheck(host))
        items.append(storageCheck(paths))
        items.append(diskCheck(paths))
        items.append(anyRuntimeCheck(installations))
        items.append(runtimeCheck(.sglang, installations: installations))
        items.append(runtimeCheck(.sglangOmni, installations: installations))

        let probe = await runtimeProbe(installations: installations, paths: paths)
        items.append(
            DiagnosticItem(
                id: "torch-mps",
                title: "PyTorch MPS",
                detail: probe?.torchMPSDetail ?? "No runnable Python environment was found.",
                status: probe?.torchMPS == true ? .passed : .failed,
                blocksReadiness: false,
                repairAction: .redetect,
                repairLabel: "Re-detect"
            )
        )
        items.append(
            DiagnosticItem(
                id: "mlx-metal",
                title: "MLX Metal",
                detail: probe?.mlxDetail ?? "No runnable Python environment was found.",
                status: probe?.mlxMetal == true ? .passed : .failed,
                blocksReadiness: false,
                repairAction: .redetect,
                repairLabel: "Re-detect"
            )
        )

        items.append(ffmpegCheck(paths: paths))
        items.append(modelCheck("Qwen/Qwen3-0.6B", models: models, engine: .sglang))
        items.append(
            modelCheck(
                "mlx-community/Qwen3-ASR-0.6B-4bit",
                models: models,
                engine: .sglangOmni
            )
        )
        items.append(portCheck(port, activePortIsExpected: activePortIsExpected))
        return DiagnosticReport(items: items)
    }

    private func platformCheck(_ host: HostSystemProfile) -> DiagnosticItem {
        if host.isSupported {
            return DiagnosticItem(
                id: "platform",
                title: "Apple Silicon macOS",
                detail: host.platformLabel,
                status: .passed
            )
        }
        return DiagnosticItem(
            id: "platform",
            title: "Apple Silicon macOS",
            detail: "SGLang Desktop requires an arm64 Mac running macOS 14 or newer.",
            status: .failed,
            repairAction: .openSoftwareUpdate,
            repairLabel: "Software Update"
        )
    }

    private func memoryCheck(_ host: HostSystemProfile) -> DiagnosticItem {
        let gib = Double(host.physicalMemoryBytes) / 1_073_741_824
        let formatted = String(format: "%.0f GB unified memory", gib)
        if gib >= 8 {
            return DiagnosticItem(
                id: "memory",
                title: "Unified memory",
                detail: formatted,
                status: .passed
            )
        }
        return DiagnosticItem(
            id: "memory",
            title: "Unified memory",
            detail: "\(formatted); the current test models require at least 8 GB.",
            status: .warning,
            blocksReadiness: false
        )
    }

    private func storageCheck(_ paths: AppPaths) -> DiagnosticItem {
        let probe = paths.state.appending(path: ".diagnostic-write-probe")
        do {
            try paths.createRequiredDirectories()
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return DiagnosticItem(
                id: "storage",
                title: "Application storage",
                detail: paths.root.path,
                status: .passed
            )
        } catch {
            return DiagnosticItem(
                id: "storage",
                title: "Application storage",
                detail: error.localizedDescription,
                status: .failed,
                repairAction: .redetect,
                repairLabel: "Try Again"
            )
        }
    }

    private func diskCheck(_ paths: AppPaths) -> DiagnosticItem {
        let values = try? paths.root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let bytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let gib = Double(bytes) / 1_073_741_824
        return DiagnosticItem(
            id: "disk",
            title: "Free disk space",
            detail: String(format: "%.1f GB available", gib),
            status: gib >= 5 ? .passed : .warning,
            blocksReadiness: false
        )
    }

    private func runtimeCheck(
        _ engine: EngineKind,
        installations: [RuntimeInstallation]
    ) -> DiagnosticItem {
        if let runtime = installations.first(where: {
            $0.manifest.engine == engine
                && FileManager.default.isExecutableFile(atPath: $0.executableURL.path)
        }) {
            return DiagnosticItem(
                id: "runtime-\(engine.rawValue)",
                title: "\(engine.displayName) runtime",
                detail: runtime.manifest.displayName,
                status: .passed,
                blocksReadiness: false
            )
        }
        return DiagnosticItem(
            id: "runtime-\(engine.rawValue)",
            title: "\(engine.displayName) runtime",
            detail: "No executable runtime is registered.",
            status: .failed,
            blocksReadiness: false,
            repairAction: .openInstallations,
            repairLabel: "Add Runtime"
        )
    }

    private func anyRuntimeCheck(_ installations: [RuntimeInstallation]) -> DiagnosticItem {
        let valid = installations.filter {
            FileManager.default.isExecutableFile(atPath: $0.executableURL.path)
        }
        if !valid.isEmpty {
            return DiagnosticItem(
                id: "runtime-any",
                title: "Runnable engine",
                detail: "\(valid.count) executable runtime(s) registered.",
                status: .passed
            )
        }
        return DiagnosticItem(
            id: "runtime-any",
            title: "Runnable engine",
            detail: "At least one managed or explicitly selected local runtime is required.",
            status: .failed,
            repairAction: .openInstallations,
            repairLabel: "Add Runtime"
        )
    }

    private func ffmpegCheck(paths: AppPaths) -> DiagnosticItem {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg@7/lib"),
            paths.runtimes.appending(path: "trial-shared-apple/ffmpeg/lib"),
        ]
        if let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return DiagnosticItem(
                id: "ffmpeg",
                title: "FFmpeg 7",
                detail: found.path,
                status: .passed,
                blocksReadiness: false
            )
        }
        return DiagnosticItem(
            id: "ffmpeg",
            title: "FFmpeg 7",
            detail: "TorchCodec cannot decode audio until FFmpeg 7 is available.",
            status: .failed,
            blocksReadiness: false,
            repairAction: .openInstallations,
            repairLabel: "Repair Runtime"
        )
    }

    private func modelCheck(
        _ repository: String,
        models: [ManagedModel],
        engine: EngineKind
    ) -> DiagnosticItem {
        if let model = models.first(where: {
            $0.repository == repository
                && $0.state == .ready
                && $0.localDirectory.map {
                    FileManager.default.fileExists(atPath: $0.path)
                } == true
        }) {
            return DiagnosticItem(
                id: "model-\(repository)",
                title: repository,
                detail: model.localDirectory?.path ?? "Cached",
                status: .passed
            )
        }
        return DiagnosticItem(
            id: "model-\(repository)",
            title: repository,
            detail: "The model is not completely cached for \(engine.displayName).",
            status: .failed,
            blocksReadiness: false,
            repairAction: .openModels,
            repairLabel: "Models"
        )
    }

    private func portCheck(_ port: UInt16, activePortIsExpected: Bool) -> DiagnosticItem {
        if LocalPort.isAvailable(port) || activePortIsExpected {
            return DiagnosticItem(
                id: "port",
                title: "Local API port",
                detail: activePortIsExpected
                    ? "127.0.0.1:\(port) is owned by the running engine."
                    : "127.0.0.1:\(port) is available.",
                status: .passed,
                blocksReadiness: false
            )
        }
        return DiagnosticItem(
            id: "port",
            title: "Local API port",
            detail: "127.0.0.1:\(port) is already in use.",
            status: .failed,
            blocksReadiness: false,
            repairAction: .chooseFreePort,
            repairLabel: "Use Free Port"
        )
    }

    private func runtimeProbe(
        installations: [RuntimeInstallation],
        paths: AppPaths
    ) async -> RuntimeProbe? {
        let sharedRoot = paths.runtimes.appending(path: "trial-shared-apple")
        let python = sharedRoot.appending(path: "python/bin/python3")
        let packagePath: String? = sharedRoot.appending(path: "packages").path

        // Never auto-execute an arbitrary local Python selected by the user.
        // Only the managed Desktop runtime under AppPaths is probed.
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }

        return await Task.detached(priority: .utility) {
            let script = """
                import json
                result = {"torch_mps": False, "mlx_metal": False, "errors": []}
                try:
                    import torch
                    result["torch_mps"] = bool(torch.backends.mps.is_built() and torch.backends.mps.is_available())
                    result["torch"] = torch.__version__
                except Exception as exc:
                    result["errors"].append("torch: " + repr(exc))
                try:
                    import mlx.core as mx
                    result["mlx_metal"] = bool(mx.metal.is_available())
                except Exception as exc:
                    result["errors"].append("mlx: " + repr(exc))
                print(json.dumps(result))
                """
            let process = Process()
            let output = Pipe()
            process.executableURL = python
            process.arguments = ["-s", "-c", script]
            var environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PYTHONNOUSERSITE": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
            ]
            if let packagePath { environment["PYTHONPATH"] = packagePath }
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let decoded = try JSONDecoder().decode(RuntimeProbePayload.self, from: data)
                return RuntimeProbe(payload: decoded)
            } catch {
                return nil
            }
        }.value
    }
}

private struct RuntimeProbePayload: Codable, Sendable {
    let torchMPS: Bool
    let mlxMetal: Bool
    let torch: String?
    let errors: [String]

    enum CodingKeys: String, CodingKey {
        case torchMPS = "torch_mps"
        case mlxMetal = "mlx_metal"
        case torch
        case errors
    }
}

private struct RuntimeProbe: Sendable {
    let torchMPS: Bool
    let mlxMetal: Bool
    let torchMPSDetail: String
    let mlxDetail: String

    init(payload: RuntimeProbePayload) {
        self.torchMPS = payload.torchMPS
        self.mlxMetal = payload.mlxMetal
        self.torchMPSDetail =
            payload.torchMPS
            ? "PyTorch \(payload.torch ?? "unknown") can use Metal Performance Shaders."
            : payload.errors.first ?? "PyTorch MPS is unavailable."
        self.mlxDetail =
            payload.mlxMetal
            ? "MLX can access the Apple Metal device."
            : payload.errors.last ?? "MLX Metal is unavailable."
    }
}

public enum LocalPort {
    public static func isAvailable(_ port: UInt16) -> Bool {
        #if canImport(Darwin)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        #else
            return false
        #endif
    }

    public static func availablePort() -> UInt16? {
        #if canImport(Darwin)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard bound else { return nil }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let read = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length) == 0
                }
            }
            return read ? UInt16(bigEndian: address.sin_port) : nil
        #else
            return nil
        #endif
    }
}
