#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Downloads Live Activity
//
// Started and updated by the app (`DownloadLiveActivity`) while downloads run.

struct DownloadsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadsLockScreenView(state: context.state)
                .activityBackgroundTint(OmniWidgetStyle.ink.opacity(0.94))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadGauge(state: state, size: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(DownloadText.count(state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        if let subtitle = state.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        WidgetProgressBar(value: state.isFinished ? 1 : state.progress, height: 4)
                        Text(DownloadText.status(state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.isFinished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(OmniWidgetStyle.accent)
            } compactTrailing: {
                Text(state.isFinished ? "Done" : "\(Int(state.progress * 100))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(OmniWidgetStyle.accent)
            } minimal: {
                DownloadGauge(state: state, size: 22)
            }
            .keylineTint(OmniWidgetStyle.accent)
        }
    }
}

private struct DownloadsLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            DownloadGauge(state: state, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(state.isFinished ? "Downloads ready" : "Downloading")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OmniWidgetStyle.accent)
                    Spacer()
                    Text(DownloadText.count(state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(DownloadText.status(state))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if !state.isFinished {
                    WidgetProgressBar(value: state.progress, height: 4)
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
    }
}

/// Ring with the download's progress, or a tick when the batch is done.
private struct DownloadGauge: View {
    let state: DownloadActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: state.isFinished ? 1 : max(0.02, state.progress))
                .stroke(OmniWidgetStyle.accent, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: state.isFinished ? "checkmark" : (state.isWaitingForWiFi ? "wifi" : "arrow.down"))
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private enum DownloadText {
    /// "2 of 5", or "3 done" once finished.
    static func count(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.isFinished { return state.completed == 1 ? "1 done" : "\(state.completed) done" }
        guard state.total > 1 else { return "" }
        return "\(min(state.completed + 1, state.total)) of \(state.total)"
    }

    static func status(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.isFinished { return "Ready to watch offline" }
        if state.isWaitingForWiFi { return "Waiting for Wi-Fi" }
        var parts = ["\(Int(state.progress * 100))%"]
        if let subtitle = state.subtitle { parts.append(subtitle) }
        return parts.joined(separator: " · ")
    }
}
#endif
