// MARK: - PlayerLab / Render
//
// Responsible for presenting decoded video frames on-screen:
//   • Receive DecodedFrame from the decode layer
//   • Upload to GPU via Metal / CVPixelBuffer
//   • Drive a CAMetalLayer or AVSampleBufferDisplayLayer
//   • Feed timing info back to the presentation clock
//
// TODO: Sprint Render-1 — define FrameRenderer protocol + PresentationClock
// TODO: Sprint Render-2 — AVSampleBufferDisplayLayer-backed renderer (easy path)
// TODO: Sprint Render-3 — Metal-backed renderer for custom shader support
