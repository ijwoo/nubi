import SwiftUI
import WidgetKit

@main
struct SpikeWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpikeLiveActivity()
        SpikeControl()
    }
}
