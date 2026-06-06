import SwiftUI
import WidgetKit

// Entry point for the Xonora widget extension. The deployment floor is iOS 17, so the
// Live Activity (gated to 16.2 for `ActivityContent`) is always available here.
@main
struct XonoraWidgetBundle: WidgetBundle {
    var body: some Widget {
        XonoraLiveActivity()
    }
}
