import SwiftUI
import WidgetKit

@main
struct NubiWidgetBundle: WidgetBundle {
    var body: some Widget {
        NubiLiveActivity()
        TodayControl()
        TodayWidget()
        NextWidget()
        // 알람이 울릴 때 시스템이 이걸로 그립니다. 없으면 얼굴이 없습니다.
        if #available(iOS 26.0, *) { NubiAlarmWidget() }
    }
}
