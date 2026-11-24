import SwiftUI
import YTMPlayback

struct SleepTimerMenu: View {
    private static let minutes = [15, 30, 45, 60]

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let timer = player.sleepTimer
        let status = status(timer)
        Menu {
            if let status {
                Section(status) {
                    Button("Turn off") { player.setSleepTimer(nil) }
                }
            }
            ForEach(Self.minutes, id: \.self) { minutes in
                Button("\(minutes) minutes") { player.setSleepTimer(.at(.now.addingTimeInterval(Double(minutes) * 60))) }
            }
            Button("End of song") { player.setSleepTimer(.endOfSong) }
        } label: {
            IconLabel(icon: .bedtime, size: 44, iconSize: 22, active: timer != nil)
        }
        // Top to bottom, though it opens upwards.
        .menuOrder(.fixed)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(status ?? "Off")
    }

    private func status(_ timer: SleepTimer?) -> String? {
        switch timer {
        case .at(let date): "Pauses at \(date.formatted(date: .omitted, time: .shortened))"
        case .endOfSong: "Stops at the end of this song"
        case nil: nil
        }
    }
}
