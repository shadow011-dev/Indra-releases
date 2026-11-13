import CoreImage

/// v506: one Core Image context for the whole app. Indra made five of its own (camera crops, camera frames, the notch's
/// snapshot blur, the scan animation and the settings tile). Each context keeps its own GPU buffers and caches, which stay
/// allocated for as long as it lives, so five of them held several times the memory one needs. A context is safe to share
/// between threads.
enum SharedCI {
    nonisolated static let context = CIContext()
}
