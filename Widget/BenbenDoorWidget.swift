import SwiftUI
import WidgetKit

struct DoorEntry: TimelineEntry { let date: Date }
struct DoorProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoorEntry { DoorEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (DoorEntry) -> Void) { completion(DoorEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoorEntry>) -> Void) {
        completion(Timeline(entries: [DoorEntry(date: Date())], policy: .never))
    }
}

struct DoorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular {
                Image(systemName: "lock.open.fill").font(.title2)
            } else if family == .accessoryRectangular {
                Label("奔奔一键开门", systemImage: "lock.open.fill").font(.headline)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "lock.open.fill").font(.system(size: 30, weight: .medium))
                        Spacer(minLength: 0)
                        Text("一键开门").font(.title2.bold())
                        Text("奔奔门锁").font(.caption).opacity(0.8)
                    }
                    Spacer(minLength: 0)
                    if family == .systemMedium {
                        Image(systemName: "arrow.up.forward.circle.fill")
                            .font(.system(size: 42)).opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .containerBackground(for: .widget) { Color.blue.gradient }
        .widgetURL(URL(string: "benbenlock://unlock"))
        .accessibilityLabel("打开奔奔 App 并执行开门")
    }
}

@main
struct BenbenDoorWidget: Widget {
    let kind = "BenbenDoorWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoorProvider()) { _ in DoorWidgetView() }
            .configurationDisplayName("奔奔一键开门")
            .description("点击后打开 App，自动连接门锁并开门。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
