import Foundation

public struct HealthProbe: Sendable {
    public init() {}

    public func isReady(url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map {
                (200..<300).contains($0.statusCode)
            } ?? false
        } catch {
            return false
        }
    }

    public func waitUntilReady(
        url: URL,
        timeout: Duration = .seconds(30),
        interval: Duration = .milliseconds(250)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await isReady(url: url) { return true }

            try? await clock.sleep(for: interval)
        }
        return false
    }
}
