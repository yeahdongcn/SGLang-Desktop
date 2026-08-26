import Foundation

public struct HealthProbe: Sendable {
    public init() {}

    public func waitUntilReady(
        url: URL,
        timeout: Duration = .seconds(30),
        interval: Duration = .milliseconds(250)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                let (_, response) = try await URLSession.shared.data(for: request)
                if let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode)
                {
                    return true
                }
            } catch {
                // Startup polling intentionally tolerates connection failures.
            }

            try? await clock.sleep(for: interval)
        }
        return false
    }
}
