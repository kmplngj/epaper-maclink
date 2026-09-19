import AppKit
import SwiftUI
import MacLinkCore

@main
struct MacLinkApp: App {
    @StateObject private var model=AppModel()
    init() {
        if let index=CommandLine.arguments.firstIndex(of:"--render-demo"),CommandLine.arguments.count>index+1 {
            let output=CommandLine.arguments[index+1]
            var settings=DisplaySettings(id:"demo",name:"Desk")
            settings.calendarIDs=["demo"];settings.reminderLists=[ReminderListSelection(id:"demo")]
            let now=ISO8601DateFormatter().date(from:"2026-09-13T08:00:00Z")!
            let events=(0..<7).map { index in AgendaItem(id:"\(index)",title:["Plan the week","Design review","Focus time","Project catch-up","Lunch with Sam","Weekend walk","Prepare for Monday"][index],start:now.addingTimeInterval(Double(index)*86400+3600),end:now.addingTimeInterval(Double(index)*86400+7200),allDay:false,calendarName:"Personal") }
            let groups=[TaskGroup(name:"Personal",items:[TaskItem(id:"a",title:"Pick up groceries",due:now,dateOnly:true),TaskItem(id:"b",title:"Book the bike service",due:nil)]),TaskGroup(name:"Projects",items:[TaskItem(id:"c",title:"Review the display layout",due:now.addingTimeInterval(86400))])]
            do {
                let frame=try DashboardRenderer.render(settings:settings,events:events,groups:groups,now:now)
                try frame.png.write(to:URL(fileURLWithPath:output));print(frame.pixelHash);exit(0)
            } catch { fputs("\(error)\n",stderr);exit(1) }
        }
    }
    var body: some Scene {
        Window("MacLink",id:"main") {
            MainView(model:model)
        }
        .defaultSize(width:1080,height:760)
        .windowResizability(.contentMinSize)
        MenuBarExtra("MacLink",systemImage:"rectangle.inset.filled") {
            MenuView(model:model)
        }
    }
}

struct MenuView: View {
    @ObservedObject var model:AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.error ?? model.message)
        Button("Open MacLink") { openWindow(id:"main");NSApplication.shared.activate(ignoringOtherApps:true) }
            .keyboardShortcut(",")
        Button("Check for changes") { Task { await model.checkForChanges() } }.disabled(model.working)
        Divider()
        Button("Quit MacLink") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainView:View {
    @ObservedObject var model:AppModel
    @State private var tab="Content"
    @State private var newName=""
    @State private var adding=false
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:0) {
                Text("Your displays").font(.headline).padding(16)
                List(selection:Binding(get:{model.selectedID},set:{model.select($0)})) {
                    ForEach(model.settings.displays) { display in
                        Label(display.name,systemImage:"rectangle").tag(display.id)
                    }
                }
                HStack {
                    Button { adding=true } label:{ Label("Add display",systemImage:"plus") }.disabled(!model.connected)
                    Spacer()
                }.padding(12)
            }
            .navigationSplitViewColumnWidth(min:170,ideal:200,max:260)
        } detail: {
            VStack(alignment:.leading,spacing:0) {
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(model.current?.name ?? "MacLink").font(.largeTitle.weight(.semibold))
                        Text("Your week, at a glance.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                    Button("Check for changes") { Task { await model.checkForChanges() } }.disabled(model.working || model.current==nil)
                }.padding(24)
                if let error=model.error {
                    HStack(alignment:.top) {
                        Image(systemName:"exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer()
                    }.padding(12).background(Color.orange.opacity(0.12)).padding(.horizontal,24).padding(.bottom,12)
                }
                TabView(selection:$tab) {
                    if let current=model.current {
                        ContentSettings(model:model,apple:model.apple,display:current)
                            .id(current.id).tabItem { Text("Content") }.tag("Content")
                        PreviewView(model:model).tabItem { Text("Preview") }.tag("Preview")
                        FirmwareView(model:model,firmware:model.firmware,display:current).tabItem { Text("Firmware") }.tag("Firmware")
                        BatteryView(model:model,display:current).id(current.id).tabItem { Text("Battery") }.tag("Battery")
                    } else {
                        VStack(spacing:16) {
                            Image(systemName:"rectangle.badge.plus").font(.system(size:40)).foregroundStyle(.secondary)
                            Text("Set up your first display").font(.title2.weight(.semibold))
                            Text("Connect the home server, then add a display and choose what it shows.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Open connection settings") { tab="Connection" }
                        }.frame(maxWidth:.infinity,maxHeight:.infinity).tabItem { Text("Content") }.tag("Content")
                    }
                    ConnectionView(model:model).tabItem { Text("Connection") }.tag("Connection")
                    HomeAssistantView(model:model,home:model.homeAssistant).tabItem { Text("Home Assistant") }.tag("Home Assistant")
                }.padding(.horizontal,20)
                HStack {
                    Image(systemName:model.connected ? "checkmark.circle":"network.slash")
                    Text(model.message).lineLimit(1)
                    Spacer()
                    Text("Continues in the menu bar").foregroundStyle(.secondary)
                }.font(.caption).padding(16)
            }.frame(minWidth:720,minHeight:650)
        }
        .sheet(isPresented:$adding) {
            VStack(alignment:.leading,spacing:18) {
                Text("Add a display").font(.title2.weight(.semibold))
                TextField("Display name",text:$newName).textFieldStyle(.roundedBorder)
                Text("800 × 480 monochrome · each display has its own content settings.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer();Button("Cancel") { adding=false };Button("Add") { let name=newName;newName="";adding=false;Task { await model.addDisplay(name:name) } }.disabled(newName.trimmingCharacters(in:.whitespaces).isEmpty).keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width:410)
        }
    }
}

struct ContentSettings:View {
    @ObservedObject var model:AppModel
    @ObservedObject var apple:AppleData
    @State var display:DisplaySettings
    var body: some View {
        Form {
            Section {
                Toggle("Publish updates for this display",isOn:$display.enabled)
                Toggle("Fit as many days as possible",isOn:$display.autoFitDays)
                if !display.autoFitDays { Stepper("Look ahead up to \(display.calendarDays) days",value:$display.calendarDays,in:1...31) }
                Text("Every displayed day includes all its entries. Automatic fitting looks ahead up to a month and uses the available space.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Calendars") {
                if !apple.calendarGranted {
                    Text("Allow Calendar access, then choose which calendars appear on this display.").foregroundStyle(.secondary)
                    Button("Allow Calendar access") { Task { await apple.requestCalendars();model.schedule() } }
                } else if apple.calendars.isEmpty {
                    Text("No calendars available. Check your accounts in Calendar.").foregroundStyle(.secondary)
                } else {
                    ForEach(apple.calendars,id:\.calendarIdentifier) { calendar in
                        VStack(alignment:.leading,spacing:8) {
                            Toggle(isOn:Binding(get:{display.calendarIDs.contains(calendar.calendarIdentifier)},set:{ on in if on { display.calendarIDs.insert(calendar.calendarIdentifier) } else { display.calendarIDs.remove(calendar.calendarIdentifier) } })) {
                                HStack { Text(calendar.title);Spacer();Text(calendar.source.title).font(.caption).foregroundStyle(.secondary) }
                            }
                            .accessibilityLabel("\(calendar.title), \(calendar.source.title)")
                            if display.calendarIDs.contains(calendar.calendarIdentifier) {
                                HStack {
                                    Text("Abbreviation").font(.caption).foregroundStyle(.secondary)
                                    TextField("e.g. FAM",text:Binding(get:{display.abbreviation(for:calendar.calendarIdentifier,name:calendar.title)},set:{display.calendarAbbreviations[calendar.calendarIdentifier]=String($0.prefix(6))}))
                                        .textFieldStyle(.roundedBorder).frame(width:82)
                                        .accessibilityLabel("Abbreviation for \(calendar.title)")
                                    Text("Up to 6 characters; leave empty to hide.").font(.caption).foregroundStyle(.secondary)
                                }.padding(.leading,12)
                            }
                        }
                    }
                }
            }
            Section("Reminder lists") {
                if !apple.remindersGranted {
                    Text("Choose lists and a sort order for each one. Completed reminders stay hidden.").foregroundStyle(.secondary)
                    Button("Allow Reminders access") { Task { await apple.requestReminders();model.schedule() } }
                } else if apple.lists.isEmpty {
                    Text("No reminder lists available. Check your accounts in Reminders.").foregroundStyle(.secondary)
                } else {
                    ForEach(apple.lists,id:\.calendarIdentifier) { list in
                        VStack(alignment:.leading,spacing:10) {
                            Toggle(list.title,isOn:Binding(get:{display.reminderLists.contains {$0.id==list.calendarIdentifier}},set:{ on in
                                if on { display.reminderLists.append(ReminderListSelection(id:list.calendarIdentifier)) }
                                else { display.reminderLists.removeAll {$0.id==list.calendarIdentifier} }
                            }))
                            if let index=display.reminderLists.firstIndex(where:{$0.id==list.calendarIdentifier}) {
                                HStack {
                                    Picker("Sort by",selection:$display.reminderLists[index].sort) { ForEach(ReminderSort.allCases) { Text($0.label).tag($0) } }.frame(maxWidth:280)
                                    Picker("Order",selection:$display.reminderLists[index].ascending) { Text("Ascending").tag(true);Text("Descending").tag(false) }.labelsHidden().frame(width:130)
                                }.padding(.leading,24)
                            }
                        }.padding(.vertical,3)
                    }
                    Toggle("Include reminders without a due date",isOn:$display.includeUndated)
                    Text("Lists appear in the order you select them. Undated reminders sort last.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of:display) { _,new in
            guard var edited=model.settings.displays.first(where:{$0.id==new.id}) else { return }
            edited.enabled=new.enabled;edited.calendarDays=new.calendarDays;edited.autoFitDays=new.autoFitDays
            edited.calendarIDs=new.calendarIDs;edited.calendarAbbreviations=new.calendarAbbreviations
            edited.reminderLists=new.reminderLists;edited.includeUndated=new.includeUndated
            model.update(edited)
        }
    }
}

struct PreviewView:View {
    @ObservedObject var model:AppModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if let image=model.preview {
                    Image(nsImage:image).resizable().interpolation(.none).aspectRatio(contentMode:.fit)
                        .background(.white).border(Color.secondary.opacity(0.4),width:1)
                    Text("Exact display pixels · \(model.current?.width ?? 800) × \(model.current?.height ?? 480)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Preparing your preview",systemImage:"rectangle",description:Text("Choose calendars or reminder lists in Content."))
                }
                if let status=model.remote.first(where:{$0.id==model.selectedID}) {
                    LabeledContent("Server image",value:status.digest == nil ? "No image yet":"Published")
                    LabeledContent("Display confirmation",value:status.digest != nil && status.delivered_digest==status.digest ? "Current image confirmed":"Waiting for the display")
                    LabeledContent("Last seen",value:status.last_seen ?? "Not connected yet")
                }
                Text("The home server keeps the latest image available while this Mac sleeps. Calendar, reminder and Home Assistant updates publish when macOS allows the app to run.").font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

struct ConnectionView:View {
    @ObservedObject var model:AppModel
    var body: some View {
        Form {
            Section("Home server") {
                TextField("Server URL",text:$model.settings.serverURL)
                SecureField("Access token",text:$model.accessToken)
                Text("Your token is saved in macOS Keychain. The app publishes only the content selected for each display.").font(.caption).foregroundStyle(.secondary)
                Button(model.connected ? "Reconnect":"Connect") { Task { await model.connect() } }.disabled(model.working)
            }
            Section("Background updates") {
                Toggle("Open MacLink at login",isOn:Binding(get:{model.launchAtLogin},set:{model.setLogin($0)}))
                Text("Updates follow source changes, time boundaries and Mac wake. Discretionary checks run approximately every 15 minutes; sleep-time execution is controlled by macOS.").foregroundStyle(.secondary)
            }
            Section("Access") {
                Text("Calendar and Reminders permissions can be changed in System Settings → Privacy & Security.").foregroundStyle(.secondary)
                Button("Refresh available calendars and lists") { model.apple.reloadSources();model.schedule() }
            }
        }.formStyle(.grouped)
    }
}
