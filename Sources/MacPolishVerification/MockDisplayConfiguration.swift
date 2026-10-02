import Foundation
import MacPolishKit

@MainActor
final class MockDisplayConfiguration {
    var configuration = DisplayConfiguration(displays: [
        .init(identifier: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    ])

    func changeGeometry() {
        let display = configuration.displays[0]
        let frame = CGRect(x: display.frame.minX, y: display.frame.minY, width: display.frame.width + 100, height: display.frame.height)
        configuration = DisplayConfiguration(displays: [.init(identifier: display.identifier, frame: frame, scale: display.scale)])
    }
}
