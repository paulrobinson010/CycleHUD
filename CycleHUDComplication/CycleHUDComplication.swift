import WidgetKit
import SwiftUI

struct CycleHUDEntry: TimelineEntry { let date: Date }

struct CycleHUDProvider: TimelineProvider {
    func placeholder(in context: Context) -> CycleHUDEntry { CycleHUDEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (CycleHUDEntry) -> Void) {
        completion(CycleHUDEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CycleHUDEntry>) -> Void) {
        completion(Timeline(entries: [CycleHUDEntry(date: Date())], policy: .never))
    }
}

struct CycleHUDComplicationView: View {
    @Environment(\.widgetFamily) private var family
    private var logo: some View { Image("AppLogo").resizable().scaledToFit() }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); logo.padding(3) }
        case .accessoryCorner:
            logo.widgetLabel("CycleHUD")
        case .accessoryInline:
            Label("CycleHUD", systemImage: "dot.radiowaves.left.and.right")
        case .accessoryRectangular:
            HStack(spacing: 6) { logo.frame(width: 26, height: 26); Text("CycleHUD").fontWeight(.semibold) }
        default:
            logo
        }
    }
}

struct CycleHUDComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CycleHUDComplication", provider: CycleHUDProvider()) { _ in
            CycleHUDComplicationView()
        }
        .configurationDisplayName("CycleHUD")
        .description("Open CycleHUD from your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
