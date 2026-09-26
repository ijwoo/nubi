import SwiftUI
import WidgetKit

@main
struct NubiWidgetBundle: WidgetBundle {
    var body: some Widget {
        NubiLiveActivity()
        TodayControl()
        TodayWidget()
    }
}
