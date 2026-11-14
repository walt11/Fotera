import ActivityKit
import SwiftUI
import WidgetKit

struct BackupActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BackupActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: context.state.symbol).font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fotera").font(.caption).foregroundStyle(.secondary)
                        Text(context.isStale ? "Waiting for an update" : context.state.title).font(.headline)
                    }
                    Spacer()
                    Text("\(context.state.percent)%").font(.title2.bold()).monospacedDigit()
                }
                ProgressView(value: context.state.fraction).tint(.blue)
                HStack {
                    Text("\(context.state.completed.formatted()) of \(context.state.total.formatted()) backed up")
                    Spacer()
                    if context.state.awaitingVerification > 0 {
                        Text("\(context.state.awaitingVerification) verifying")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color(.secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(URL(string: "fotera://backup"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Fotera", systemImage: context.state.symbol).font(.headline).foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.percent)%").font(.headline).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(context.isStale ? "Waiting for an update" : context.state.title)
                                .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text("\(context.state.completed.formatted()) / \(context.state.total.formatted())")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .accessibilityLabel("\(context.state.completed) of \(context.state.total) backed up")
                        }
                        ProgressView(value: context.state.fraction).tint(.blue)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(context.state.percent)%").font(.caption2).monospacedDigit().foregroundStyle(.blue)
            } minimal: {
                ProgressView(value: context.state.fraction).progressViewStyle(.circular).tint(.blue)
            }
            .widgetURL(URL(string: "fotera://backup"))
            .keylineTint(.blue)
        }
    }
}
