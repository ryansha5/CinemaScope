// MARK: - PlayerLab / IO
//
// Responsible for opening byte-level access to media sources:
//   • Local files
//   • HTTP byte-range streams (for future direct-play of remote MKV / MP4)
//   • In-memory buffers (for unit tests)
//
// TODO: Sprint IO-1 — define MediaReader protocol + LocalFileReader conformance
// TODO: Sprint IO-2 — HTTPRangeReader (byte-range fetch, adaptive buffering)
// TODO: Sprint IO-3 — cache / prefetch layer
