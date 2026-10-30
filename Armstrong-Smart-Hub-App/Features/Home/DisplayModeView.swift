import SwiftUI

/// The always-on panel from /display: a big clock, devices and downloads, with
/// the screen kept awake while it's open.
struct DisplayModeView: View {
    let store: HomeStore

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .bottom) {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 76, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                .font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Leave display mode", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                }

                DeviceGroups(store: store, large: true, onOpen: { e in
                    if e.isTV { remote = e } else { light = e }
                }, onToggle: { e in
                    Task { await store.toggle(e, api: session.api, toast: toast) }
                })

                if !store.activeDownloads.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Downloads", meta: "\(store.activeDownloads.count) in progress")
                        RequestList(requests: store.activeDownloads) { _ in }
                    }
                }
            }
            .padding(24)
        }
        .hubPageStyle()
        .task { await store.poll(api: session.api) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .sheet(item: $light) { e in
            LightSheet(entityID: e.id, store: store, toast: toast).presentationDetents([.medium, .large])
        }
        .sheet(item: $remote) { e in
            RemoteSheet(entity: store.entity(e.id) ?? e)
        }
        .toast(toast)
    }
}
