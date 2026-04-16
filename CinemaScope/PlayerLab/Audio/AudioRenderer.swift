// MARK: - PlayerLab / Audio
//
// Responsible for audio decode and presentation:
//   • Decode compressed audio (AAC, AC-3, DTS, TrueHD — via AudioToolbox)
//   • Mix and route to AVAudioEngine / AVAudioSession
//   • Sync audio clock to the presentation timeline
//
// TODO: Sprint Audio-1 — define AudioRenderer protocol + PCMBuffer type
// TODO: Sprint Audio-2 — AudioToolbox-backed AAC / AC-3 decoder
// TODO: Sprint Audio-3 — AVAudioEngine output stage + clock sync
