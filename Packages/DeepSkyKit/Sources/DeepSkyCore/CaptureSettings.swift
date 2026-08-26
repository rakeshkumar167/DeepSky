import Foundation

public struct CaptureSettings: Sendable, Codable, Hashable {
    public var lensIndex: Int
    public var iso: Float
    public var exposure: ShutterSpeed
    public var lensPosition: Float
    public var whiteBalanceKelvin: Int
    public var exposureBias: Float

    public init(lensIndex: Int, iso: Float, exposure: ShutterSpeed,
                lensPosition: Float, whiteBalanceKelvin: Int, exposureBias: Float) {
        self.lensIndex = lensIndex
        self.iso = iso
        self.exposure = exposure
        self.lensPosition = lensPosition
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.exposureBias = exposureBias
    }
}
