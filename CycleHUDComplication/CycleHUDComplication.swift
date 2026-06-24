import WidgetKit
import SwiftUI

// CycleHUD watch-face complication.
//
// A lightweight "launch the app" complication that shows the CycleHUD radar
// glyph on the watch face. It carries no live data (no App Group needed) — its
// only job is to put a recognisable CycleHUD icon on the face that opens the app
// in one tap. Add the live speed/threat later by sharing state via an App Group.
//
// This is the @main of a **Widget Extension** target — see docs/SETUP.md for how
// to add that target in Xcode and drop this file into it.

private let glyph = "dot.radiowaves.left.and.right"   // matches the app's radar icon

struct CycleHUDEntry: TimelineEntry {
    let date: Date
}

struct CycleHUDProvider: TimelineProvider {
    func placeholder(in context: Context) -> CycleHUDEntry { CycleHUDEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (CycleHUDEntry) -> Void) {
        completion(CycleHUDEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CycleHUDEntry>) -> Void) {
        // Static glyph — no schedule needed.
        completion(Timeline(entries: [CycleHUDEntry(date: Date())], policy: .never))
    }
}

struct CycleHUDComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: glyph).font(.system(size: 18, weight: .bold))
            }
        case .accessoryCorner:
            Image(systemName: glyph)
                .font(.system(size: 20, weight: .bold))
                .widgetLabel("CycleHUD")
        case .accessoryInline:
            Label("CycleHUD", systemImage: glyph)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: glyph)
                Text("CycleHUD").fontWeight(.semibold)
            }
        default:
            Image(systemName: glyph)
        }
    }
}

@main
struct CycleHUDComplication: Widget {
    let kind = "CycleHUDComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CycleHUDProvider()) { _ in
            CycleHUDComplicationView()
        }
        .configurationDisplayName("CycleHUD")
        .description("Open CycleHUD from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
