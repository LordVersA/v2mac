import Foundation
import SwiftData
import V2MacCore

/// Background writer for latency results.
@ModelActor
actor LatencyStore {
    func apply(id: UUID, outcome: LatencyOutcome?, kind: String) throws {
        guard let profile = try modelContext.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first else { return }
        profile.delayKindRaw = kind
        profile.delayTestedAt = Date()
        switch outcome {
        case .ok(let ms)?:
            profile.delayState = .ok
            profile.delayMs = ms
        case .timeout?:
            profile.delayState = .timeout
            profile.delayMs = nil
        case .invalid?:
            profile.delayState = .invalid
            profile.delayMs = nil
        case nil:
            profile.delayState = .na
            profile.delayMs = nil
        }
        try modelContext.save()
    }

    func applySpeed(id: UUID, outcome: SpeedOutcome?) throws {
        guard let profile = try modelContext.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first else { return }
        switch outcome {
        case .ok(let bps)?: profile.speedBps = bps
        case .failed?: profile.speedBps = 0
        case nil: profile.speedBps = nil
        }
        try modelContext.save()
    }
}
