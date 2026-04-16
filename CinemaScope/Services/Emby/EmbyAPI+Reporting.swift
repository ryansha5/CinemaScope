import Foundation

// MARK: - Playback Reporting
//
// All three endpoints expect a JSON POST body — NOT query parameters.
// The PlaySessionId must match the one Emby returned in PlaybackInfo
// so the server can associate reports with the active transcode job.
// PlayMethod must reflect the actual path chosen (DirectPlay / DirectStream
// / Transcode) so Emby's statistics and "Now Playing" dashboard are correct.

extension EmbyAPI {

    static func reportPlaybackStart(
        server: EmbyServer, userId: String, token: String,
        itemId: String, mediaSourceId: String,
        playSessionId: String, playMethod: String
    ) async {
        guard let url = try? urlComponents(server, path: "/Sessions/Playing").url else { return }
        let body: [String: Any] = [
            "ItemId":          itemId,
            "MediaSourceId":   mediaSourceId,
            "PlaySessionId":   playSessionId,
            "UserId":          userId,
            "PlayMethod":      playMethod,
            "PositionTicks":   0,
            "CanSeek":         true,
            "IsPaused":        false,
            "IsMuted":         false,
        ]
        _ = try? await postJSON(url: url, body: body, token: token)
    }

    static func reportPlaybackProgress(
        server: EmbyServer, token: String,
        itemId: String, mediaSourceId: String,
        playSessionId: String, playMethod: String,
        positionTicks: Int64, isPaused: Bool
    ) async {
        guard let url = try? urlComponents(server, path: "/Sessions/Playing/Progress").url else { return }
        let body: [String: Any] = [
            "ItemId":          itemId,
            "MediaSourceId":   mediaSourceId,
            "PlaySessionId":   playSessionId,
            "PlayMethod":      playMethod,
            "PositionTicks":   positionTicks,
            "IsPaused":        isPaused,
            "IsMuted":         false,
            "CanSeek":         true,
        ]
        _ = try? await postJSON(url: url, body: body, token: token)
    }

    static func reportPlaybackStop(
        server: EmbyServer, token: String,
        itemId: String, mediaSourceId: String,
        playSessionId: String, playMethod: String,
        positionTicks: Int64
    ) async {
        guard let url = try? urlComponents(server, path: "/Sessions/Playing/Stopped").url else { return }
        let body: [String: Any] = [
            "ItemId":          itemId,
            "MediaSourceId":   mediaSourceId,
            "PlaySessionId":   playSessionId,
            "PlayMethod":      playMethod,
            "PositionTicks":   positionTicks,
        ]
        _ = try? await postJSON(url: url, body: body, token: token)
    }
}
