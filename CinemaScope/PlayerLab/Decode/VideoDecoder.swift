// MARK: - PlayerLab / Decode
//
// Responsible for turning compressed packets into decoded frames:
//   • Video decode (H.264, H.265/HEVC, AV1 — via VideoToolbox when available)
//   • Subtitle decode / rendering (SRT, ASS/SSA — software)
//
// TODO: Sprint Decode-1 — define VideoDecoder protocol + DecodedFrame type
// TODO: Sprint Decode-2 — VideoToolbox-backed H.264 / HEVC decoder
// TODO: Sprint Decode-3 — software fallback decoder interface
