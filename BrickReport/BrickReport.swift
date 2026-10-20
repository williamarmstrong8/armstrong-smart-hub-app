import DeviceActivity
import SwiftUI

@main
struct BrickReport: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        TotalActivityReport { text in
            ReportView(text: text)
        }
    }
}

extension DeviceActivityReport.Context {
    static let screenTime = Self("BrickScreenTime")
}

struct TotalActivityReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .screenTime
    let content: (ReportData) -> ReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ReportData {
        var total: TimeInterval = 0
        var perApp: [String: TimeInterval] = [:]
        for await d in data {
            for await seg in d.activitySegments {
                total += seg.totalActivityDuration
                for await cat in seg.categories {
                    for await app in cat.applications {
                        let name = app.application.localizedDisplayName ?? "App"
                        perApp[name, default: 0] += app.totalActivityDuration
                    }
                }
            }
        }
        let top = perApp.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
        return ReportData(total: total, top: Array(top))
    }
}

struct ReportData {
    var total: TimeInterval
    var top: [(String, TimeInterval)]
}

struct ReportView: View {
    let text: ReportData
    init(text: ReportData) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fmt(text.total)).font(.largeTitle.bold())
            Text("total screen time").font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(text.top.enumerated()), id: \.offset) { _, row in
                HStack { Text(row.0); Spacer(); Text(fmt(row.1)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func fmt(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
