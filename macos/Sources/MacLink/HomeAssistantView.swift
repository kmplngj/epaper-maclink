import SwiftUI
import MacLinkCore

struct HomeAssistantView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var home:HomeAssistant
    @State private var address=""
    @State private var token=""
    @State private var error:String?
    @State private var choosing=false
    private var footer:Binding<SensorFooterSettings> {
        Binding(get:{model.current?.footer ?? SensorFooterSettings()},set:{ value in
            guard var display=model.current else { return };display.footer=value;model.update(display)
        })
    }
    var body:some View {
        Form {
            Section("Home Assistant connection · all displays") {
                TextField("Home Assistant URL",text:$address,prompt:Text("http://homeassistant.local:8123"))
                SecureField("Long-lived access token",text:$token)
                Text("Create a token in your Home Assistant profile → Security. MacLink stores it in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(home.ready ? "Save and reconnect":"Connect / Retry") {
                        do { try model.connectHomeAssistant(url:address,token:token);error=nil }
                        catch { self.error=error.localizedDescription }
                    }.disabled(address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || token.isEmpty)
                    if model.settings.homeAssistant?.enabled == true {
                        Button("Disconnect") { model.disconnectHomeAssistant() }
                    }
                    Spacer()
                    if home.connecting { ProgressView().controlSize(.small) }
                    Text(home.status).foregroundStyle(.secondary)
                }
                if let message=error ?? home.problem {
                    Label(message,systemImage:"exclamationmark.triangle").foregroundStyle(.primary).textSelection(.enabled)
                }
            }
            if let display=model.current {
                Section("Sensor footer · \(display.name)") {
                    Toggle("Show sensor footer",isOn:footer.enabled)
                    if display.footer.enabled {
                        HStack {
                            Picker("Sample readings every",selection:footer.refreshMinutes) {
                                ForEach([5,15,30,60,180,360],id:\.self) { Text($0<60 ? "\($0) minutes":"\($0/60) hour\($0==60 ? "":"s")").tag($0) }
                            }
                            Picker("Maximum lines per item",selection:footer.lines) { ForEach(1...3,id:\.self) { Text("\($0)").tag($0) } }
                        }
                        Text("Up to four items in reading order. Short readings share a row; longer summaries get more width on a second row. Only the lines needed are reserved below the calendar.").font(.caption).foregroundStyle(.secondary)
                        if display.footer.items.isEmpty {
                            Text("Add a sensor to start your footer. No display space is reserved until you add one.").foregroundStyle(.secondary)
                        }
                        ForEach(display.footer.items) { item in
                            SensorFooterItemEditor(item:Binding(get:{model.current?.footer.items.first {$0.id==item.id} ?? item},set:{ value in
                                guard var current=model.current,let index=current.footer.items.firstIndex(where:{$0.id==item.id}) else { return }
                                current.footer.items[index]=value;model.update(current)
                            }),reading:home.readings[item.entityID],move:{ direction in move(item.id,direction:direction) },remove:{ remove(item.id) },first:display.footer.items.first?.id==item.id,last:display.footer.items.last?.id==item.id)
                        }
                        HStack {
                            Button("Add sensor",systemImage:"plus") { choosing=true }.disabled(!home.ready || display.footer.items.count>=4)
                            Spacer()
                            Button("Sample now") { Task { await model.checkForChanges() } }.disabled(!home.ready || model.working)
                        }
                        if !home.ready { Text("Connect Home Assistant to browse your sensors.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Display updates") {
                Text("Only selected readings are rendered. When Home Assistant disconnects, the last sampled values are marked stale. The Mac must be awake to publish new readings or a stale indicator.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { address=model.settings.homeAssistant?.url ?? "";token=Keychain.get("home-assistant") }
        .sheet(isPresented:$choosing) {
            SensorPicker(home:home) { sensor in
                guard var display=model.current,display.footer.items.count<4 else { return }
                var item=SensorFooterItem(entityID:sensor.id,label:sensor.name)
                switch sensor.attributes["device_class"] {
                case "door","window","opening","garage_door": item.onText="Open";item.offText="Closed"
                case "running": item.onText="Running";item.offText="Idle"
                case "motion","occupancy","presence": item.onText="Detected";item.offText="Clear"
                default: break
                }
                display.footer.items.append(item);model.update(display)
            }
        }
    }
    private func move(_ id:String,direction:Int) {
        guard var display=model.current,let index=display.footer.items.firstIndex(where:{$0.id==id}),display.footer.items.indices.contains(index+direction) else { return }
        display.footer.items.swapAt(index,index+direction);model.update(display)
    }
    private func remove(_ id:String) {
        guard var display=model.current else { return };display.footer.items.removeAll {$0.id==id};model.update(display)
    }
}

private struct SensorFooterItemEditor:View {
    @Binding var item:SensorFooterItem
    let reading:SensorReading?
    let move:(Int)->Void
    let remove:()->Void
    let first:Bool
    let last:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(reading?.name ?? item.entityID).font(.headline)
                    Text(item.entityID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { move(-1) } label:{ Image(systemName:"arrow.left") }.disabled(first).help("Move left").accessibilityLabel("Move \(item.label) left")
                Button { move(1) } label:{ Image(systemName:"arrow.right") }.disabled(last).help("Move right").accessibilityLabel("Move \(item.label) right")
                Button(role:.destructive,action:remove) { Image(systemName:"minus.circle") }.help("Remove sensor").accessibilityLabel("Remove \(item.label)")
            }
            TextField("Display label",text:$item.label,prompt:Text("Leave empty for content only"))
            Picker("Value",selection:$item.attribute) {
                Text("Sensor state").tag("")
                ForEach(Array(Set((reading?.attributes.keys.map {$0} ?? []) + (item.attribute.isEmpty ? []:[item.attribute]))).sorted(),id:\.self) { Text("Attribute: \($0)").tag($0) }
            }
            Picker("Format",selection:$item.format) { ForEach(SensorTextFormat.allCases) { Text($0.label).tag($0) } }
            if item.format == .markdown {
                Text("**Bold** and *emphasis* use bold pixel text. Line breaks are kept when space allows; links show their label. Long content ends with an ellipsis.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Decimal places",selection:$item.decimals) { ForEach(0...3,id:\.self) { Text("\($0)").tag($0) } }
                Toggle("Automatic unit",isOn:$item.automaticUnit)
            }
            if !item.automaticUnit { TextField("Unit",text:$item.unit,prompt:Text("Leave empty to hide")) }
            if item.entityID.hasPrefix("binary_sensor."),item.attribute.isEmpty {
                HStack { TextField("When on",text:$item.onText);TextField("When off",text:$item.offText) }
            }
            let value=SensorFormatting.value(for:item,reading:reading)
            Text("Current value: \(value.text)").font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }.padding(.vertical,8)
    }
}

private struct SensorPicker:View {
    @ObservedObject var home:HomeAssistant
    let choose:(SensorReading)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    @State private var selected:String?
    private var matches:[SensorReading] {
        home.sensors.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Add a sensor").font(.title2.weight(.semibold))
            TextField("Search names or entity IDs",text:$search).textFieldStyle(.roundedBorder)
            if matches.isEmpty {
                ContentUnavailableView("No sensors found",systemImage:"magnifyingglass",description:Text(home.ready ? "Try another search. Only sensors and binary sensors are listed.":"Reconnect Home Assistant, then try again."))
            } else {
                List(matches,selection:$selected) { sensor in
                    VStack(alignment:.leading,spacing:4) {
                        Text(sensor.name)
                        Text("\(sensor.id) · \(sensor.state)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(sensor.id)
                }
            }
            HStack {
                Text("\(matches.count) sensors").font(.caption).foregroundStyle(.secondary)
                Spacer();Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { if let selected,let sensor=home.readings[selected] { choose(sensor);dismiss() } }
                    .disabled(!home.ready || !matches.contains {$0.id==selected}).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:560,height:480)
    }
}
