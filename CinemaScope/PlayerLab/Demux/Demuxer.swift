// MARK: - PlayerLab / Demux
//
// Responsible for container parsing and stream extraction:
//   • Identify container format (MKV / MP4 / TS / …)
//   • Extract elementary streams (video, audio, subtitle tracks)
//   • Deliver time-stamped packets to the decode layer
//
// TODO: Sprint Demux-1 — define Demuxer protocol + PacketBuffer type
// TODO: Sprint Demux-2 — MKV/EBML parser (no AudioToolbox / VideoToolbox yet)
// TODO: Sprint Demux-3 — MP4/ISOBMFF parser
