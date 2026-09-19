import SwiftUI
import MacLinkCore

struct BatteryView:View {
    @ObservedObject var model:AppModel
    @State var display:DisplaySettings
    @State private var saving=false
    @State private var status=""
    @State private var error:String?
    private var serverReady:Bool { model.remote.first(where:{$0.id==display.id})?.schedule_enabled != nil }
    private var intervals:[Int] { Array(Set([60,300,600,900,1800,3600,7200,21600,43200,86400,display.pollSeconds])).sorted() }
    private func intervalLabel(_ seconds:Int)->String {
        seconds<3600 ? "Every \(seconds/60) minute\(seconds==60 ? "":"s")" : "Every \(seconds/3600) hour\(seconds==3600 ? "":"s")"
    }
    private func clock(_ key:WritableKeyPath<DisplaySettings,Int>)->Binding<Date> {
        Binding(get:{
            Calendar.current.date(from:DateComponents(year:2026,month:1,day:15,hour:display[keyPath:key]/60,minute:display[keyPath:key]%60))!
        },set:{ date in
            let parts=Calendar.current.dateComponents([.hour,.minute],from:date)
            display[keyPath:key]=(parts.hour ?? 0)*60+(parts.minute ?? 0)
        })
    }
    var body:some View {
        Form {
            Section("Update frequency") {
                Picker("Check for a new image",selection:$display.pollSeconds) {
                    ForEach(intervals,id:\.self) { Text(intervalLabel($0)).tag($0) }
                }
                Text("The display sleeps between checks. It downloads and refreshes only when the image pixels change. A longer interval saves battery but delays new information.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Daily update hours") {
                Toggle("Update only during these hours",isOn:$display.scheduleEnabled)
                if display.scheduleEnabled {
                    DatePicker("From",selection:clock(\.updateStart),displayedComponents:.hourAndMinute)
                    DatePicker("Until",selection:clock(\.updateEnd),displayedComponents:.hourAndMinute)
                    Picker("Time zone",selection:$display.scheduleTimezone) {
                        ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers+[display.scheduleTimezone])).sorted(),id:\.self) { Text($0.replacingOccurrences(of:"_",with:" ")).tag($0) }
                    }
                    Button("Use this Mac's time zone") { display.scheduleTimezone=TimeZone.current.identifier }
                    Text(display.updateEnd<display.updateStart ? "This window continues past midnight. Outside it, the display sleeps until the next start time.":"Outside these hours, the display sleeps until the next start time. Its last image stays visible.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Save battery settings") {
                    saving=true;error=nil;status=""
                    Task {
                        do { try await model.saveBattery(display);status="Saved. The display receives these settings at its next connection." }
                        catch { self.error=error.localizedDescription }
                        saving=false
                    }
                }.disabled(saving || !model.connected || !serverReady || (display.scheduleEnabled && display.updateStart==display.updateEnd))
                if !serverReady { Text("Update the MacLink home server to enable battery settings, then reconnect in Connection.").foregroundStyle(.orange) }
                if saving { ProgressView() }
                if display.scheduleEnabled && display.updateStart==display.updateEnd { Text("Choose different start and end times, or turn off the daily limit.").foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.orange) }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                Text("Install the latest firmware once from the Firmware tab. Later battery changes arrive from the server without reflashing. A sleeping device cannot receive changes until it wakes; a cold restart makes one initial connection to learn the time and schedule.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(saving)
            .onChange(of:display.scheduleEnabled) { _,enabled in
                if enabled && model.current?.scheduleEnabled != true { display.scheduleTimezone=TimeZone.current.identifier }
            }
    }
}
