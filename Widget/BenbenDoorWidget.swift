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
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.blue)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.16), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1) }
                        Spacer(minLength: 0)
                        Text("一键开门").font(.title2.bold())
                        Text("奔奔门锁").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if family == .systemMedium {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 54, height: 54)
                            .background(.white.opacity(0.16), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .containerBackground(for: .widget) { widgetBackground }
        .widgetURL(URL(string: "benbenlock://unlock"))
        .accessibilityLabel("打开奔奔 App 并执行开门")
    }

    // This builder needs a View. Color.blue.gradient is an AnyGradient style,
    // so returning it directly here causes the buildExpression compile error.
    private var widgetBackground: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            LinearGradient(colors: [Color.cyan.opacity(0.25), Color.blue.opacity(0.12), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
