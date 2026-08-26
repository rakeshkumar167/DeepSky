import Foundation

public enum ShutterLadder {
    /// Conventional photographic stops. This list is a *filter*, never a
    /// promise — entries survive only if the hardware reports it can
    /// actually expose for that long (spec §27 governs over §4).
    static let canonicalSeconds: [Double] = [
        1.0/8000, 1.0/4000, 1.0/2000, 1.0/1000, 1.0/500, 1.0/250,
        1.0/125, 1.0/60, 1.0/30, 1.0/15, 1.0/8, 1.0/4, 1.0/2,
        1, 2, 4, 8, 15, 20, 30,
    ]

    public static func ladder(for format: FormatCapability) -> [ShutterSpeed] {
        let lo = format.minExposureSeconds
        let hi = format.maxExposureSeconds
        guard hi > lo else { return [ShutterSpeed(seconds: lo)] }

        var values = canonicalSeconds.filter { $0 > lo && $0 < hi }
        values.append(lo)
        values.append(hi)

        let unique = Array(Set(values)).sorted()
        return unique.map(ShutterSpeed.init(seconds:))
    }
}
