// MARK: - PlaybackEngine: PlayerEngine
//
// PlaybackEngine already declares every property and method required by
// PlayerEngine, so this conformance extension is intentionally empty.
// Adding conformance here (rather than in PlaybackEngine.swift itself) keeps
// the protocol dependency out of the core engine file and makes it trivial to
// remove or swap if the protocol ever changes.

extension PlaybackEngine: PlayerEngine {}
