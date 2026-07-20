import NucleusTextBackend

@MainActor
func installTestTextBackend() {
    SkiaTextLayoutBackend.installIfNeeded()
}
