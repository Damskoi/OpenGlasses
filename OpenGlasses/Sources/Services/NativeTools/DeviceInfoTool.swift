import Foundation
import UIKit

/// Reports device battery level, low power mode, and storage info.
struct DeviceInfoTool: NativeTool {
    let name = "device_info"
    let description = "Get device information: battery level, low power mode status, and available storage."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        var info: [String] = []

        // Battery
        let batteryInfo = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let state = UIDevice.current.batteryState
            return (level, state)
        }

        let level = batteryInfo.0
        let state = batteryInfo.1

        if level >= 0 {
            let pct = Int(level * 100)
            var batteryStr = "Battery: \(pct)%"
            switch state {
            case .charging: batteryStr += " (charging)"
            case .full: batteryStr += " (fully charged)"
            case .unplugged: break
            default: break
            }
            info.append(batteryStr)
        }

        // Low Power Mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            info.append("Low Power Mode is ON")
        }

        // Power posture (Plan BV): the app's current battery/thermal-aware posture, when it's
        // doing anything (a one-line reason, e.g. "conserving — glasses battery 18%"). Silent in
        // the normal posture so device_info stays terse when there's nothing to economise.
        if let posture = await MainActor.run(body: { PowerPolicyService.shared.explanation }) {
            info.append("Power posture: \(posture)")
        }

        // Storage
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            let gb = Double(freeSpace) / 1_073_741_824.0
            info.append(String(format: "Available storage: %.1f GB", gb))
        }

        return info.isEmpty ? "Couldn't retrieve device info." : info.joined(separator: ". ") + "."
    }
}
