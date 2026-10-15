import Foundation

/// Spec 9.7, conditions: the live download rate never reached `floor` in the last `seconds`
/// while traffic flowed. Idle seconds (under 1 KB/s) do not count, so a quiet connection never
/// looks slow; at least a quarter of the window must have carried traffic.
public struct SlowSpeedWatch: Sendable {
    public let floor: Double
    public let seconds: Int
    /// One rate per second, newest last.
    private var rates: [Double] = []
    static let idle: Double = 1024

    public init(floor bytesPerSecond: Double, minutes: Int) {
        floor = bytesPerSecond
        seconds = max(1, minutes) * 60
    }

    /// Adds one second's download rate; true when the window is full and slow.
    public mutating func record(_ rate: Double) -> Bool {
        rates.append(rate)
        if rates.count > seconds { rates.removeFirst(rates.count - seconds) }
        guard rates.count == seconds else { return false }
        let busy = rates.filter { $0 >= Self.idle }
        return busy.count * 4 >= seconds && (busy.max() ?? 0) < floor
    }

    /// After a switch the new server gets a whole window.
    public mutating func reset() { rates = [] }
}
