import WidgetKit
import SwiftUI

// The Widget Extension's single entry point. The `@main` lives HERE (on the
// bundle), not on the individual widget — a target may have only one `@main`.
// Xcode generates this file when you add the Widget Extension; if yours lists an
// "ExampleWidget" (or extra Control / Live Activity entries), replace its body
// with just `CycleHUDComplication()` as below.

@main
struct CycleHUDComplicationBundle: WidgetBundle {
    var body: some Widget {
        CycleHUDComplication()
    }
}
