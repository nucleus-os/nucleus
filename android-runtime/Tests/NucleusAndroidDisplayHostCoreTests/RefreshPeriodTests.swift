import NucleusAndroidDisplayHostCore
import Testing

@Test
func waylandMillihertzConvertsToRoundedComposerPeriods() {
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 59_940) == 16_683_350)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 60_000) == 16_666_667)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 120_000) == 8_333_333)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 144_000) == 6_944_444)
    #expect(composerRefreshPeriodNanoseconds(refreshMillihertz: 0) == nil)
}
