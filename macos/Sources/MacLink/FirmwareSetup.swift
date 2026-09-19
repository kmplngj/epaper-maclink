import AppKit
import SwiftUI
import MacLinkCore

@MainActor
final class FirmwareSetup:ObservableObject {
    @Published var sourceFolder:String
    @Published var ssid=""
    @Published var password=""
    @Published var port:String
    @Published var ports:[String]=[]
    @Published var working=false
    @Published var status="Enter your Wi-Fi details, build the firmware, then flash over USB."
    @Published var error:String?
    @Published var details=""
    @Published var built=false
    private var loadedID=""
    private var builtConfiguration=""

    init() {
        sourceFolder=UserDefaults.standard.string(forKey:"firmware-source-folder") ?? Bundle.main.object(forInfoDictionaryKey:"MacLinkSourceFolder") as? String ?? ""
        port=UserDefaults.standard.string(forKey:"firmware-usb-port") ?? ""
        refreshPorts()
    }
    func refreshPorts() {
        ports=((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }.sorted().map { "/dev/"+$0 }
        if port.isEmpty,ports.count==1 { port=ports[0] }
    }
    func chooseFolder() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="Choose the local epaper-maclink source folder."
        if panel.runModal() == .OK,let url=panel.url {
            sourceFolder=url.path;UserDefaults.standard.set(sourceFolder,forKey:"firmware-source-folder");built=false
        }
    }
    func load(_ id:String) {
        guard !working,loadedID != id else { return }
        loadedID=id;built=false;error=nil;details=""
        let saved=Keychain.get("wifi-"+id)
        if let data=saved.data(using:.utf8),let values=try? JSONDecoder().decode([String:String].self,from:data) {
            ssid=values["ssid"] ?? "";password=values["password"] ?? ""
        } else { ssid="";password="" }
        refreshPorts()
    }
    func saveWiFi(_ id:String) {
        do {
            let data=try JSONEncoder().encode(["ssid":ssid,"password":password])
            try Keychain.set("wifi-"+id,String(decoding:data,as:UTF8.self))
            status="Wi-Fi details saved in Keychain. Build firmware to apply them.";error=nil
        } catch { self.error=error.localizedDescription }
    }
    private func configuration(_ id:String,_ server:String)->String {
        [id,server,sourceFolder,ssid,password].joined(separator:"\u{0}")
    }
    func canFlash(_ id:String,_ server:String)->Bool {
        built && !port.isEmpty && builtConfiguration==configuration(id,server)
    }
    private func deviceToken(_ id:String)->String {
        let existing=Keychain.get("display-"+id)
        if !existing.isEmpty { return existing }
        let root=URL(fileURLWithPath:sourceFolder).appendingPathComponent(".local")
        for name in ["device-"+id+".json","device.json"] {
            guard let data=try? Data(contentsOf:root.appendingPathComponent(name)),let saved=try? JSONDecoder().decode([String:String].self,from:data),saved["id"]==id,let token=saved["token"] else { continue }
            try? Keychain.set("display-"+id,token);return token
        }
        return ""
    }
    func operate(_ action:String,display:DisplaySettings,server:String) async {
        guard !working else { return }
        error=nil;details=""
        let root=URL(fileURLWithPath:sourceFolder)
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("scripts/firmware-app.py").path) else {
            error="Choose the local MacLink source folder under Firmware tools.";return
        }
        if action != "prepare" && (display.width != 800 || display.height != 480) {
            error="This firmware supports the Seeed XIAO ESP32-C3 7.5-inch, 800 × 480 display.";return
        }
        var spec:[String:String]=["action":action]
        if action != "prepare" {
            let token=deviceToken(display.id)
            guard !token.isEmpty else { error="The pairing token for this display is unavailable on this Mac. Restore its private device file, or add a new display in MacLink.";return }
            guard !ssid.isEmpty,!password.isEmpty else { error="Enter your 2.4 GHz Wi-Fi name and password first.";return }
            saveWiFi(display.id)
            guard error==nil else { return }
            spec.merge(["displayID":display.id,"serverURL":server,"deviceToken":token,"ssid":ssid,"password":password,"port":port]) { _,new in new }
        }
        if action=="build" { built=false }
        let snapshot=configuration(display.id,server)
        working=true;status="Starting…"
        defer { working=false }
        UserDefaults.standard.set(port,forKey:"firmware-usb-port")
        do {
            let input=try JSONSerialization.data(withJSONObject:spec)
            let code=try await FirmwareRunner.run(root:root,input:input) { [weak self] line in
                Task { @MainActor in self?.receive(line) }
            }
            if code==0 {
                if action=="build" { built=true;builtConfiguration=snapshot }
            } else if error==nil { error="The firmware operation did not finish. Review Details and try again." }
        } catch { self.error="Couldn't start the firmware tools: \(error.localizedDescription)" }
    }
    private func receive(_ line:String) {
        guard let data=line.data(using:.utf8),let event=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let message=event["message"] as? String else { return }
        switch event["kind"] as? String {
        case "error":error=message
        case "log":details=String((details+"\n"+message).suffix(12000))
        default:status=message
        }
    }
}

enum FirmwareRunner {
    static func run(root:URL,input:Data,onLine:@escaping @Sendable (String)->Void) async throws -> Int32 {
        try await Task.detached(priority:.utility) {
            let process=Process(),output=Pipe(),standardInput=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            process.arguments=[root.appendingPathComponent("scripts/firmware-app.py").path]
            process.currentDirectoryURL=root
            var env=ProcessInfo.processInfo.environment
            env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PYTHONUNBUFFERED"]="1";process.environment=env
            process.standardOutput=output;process.standardError=output;process.standardInput=standardInput
            try process.run()
            standardInput.fileHandleForWriting.write(input);try? standardInput.fileHandleForWriting.close()
            var buffer=Data()
            while true {
                let chunk=output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline=buffer.firstIndex(of:10) {
                    onLine(String(decoding:buffer[..<newline],as:UTF8.self));buffer.removeSubrange(...newline)
                }
            }
            if !buffer.isEmpty { onLine(String(decoding:buffer,as:UTF8.self)) }
            process.waitUntilExit();return process.terminationStatus
        }.value
    }
}

struct FirmwareView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var firmware:FirmwareSetup
    let display:DisplaySettings
    var body:some View {
        Form {
            Section("Wi-Fi for \(display.name)") {
                TextField("Network name",text:$firmware.ssid)
                SecureField("Password",text:$firmware.password)
                Text("Use a 2.4 GHz network that can reach your home server. Wi-Fi details are saved in this Mac's Keychain for this display.").font(.caption).foregroundStyle(.secondary)
                Button("Save Wi-Fi details") { firmware.saveWiFi(display.id) }.disabled(firmware.ssid.isEmpty || firmware.password.isEmpty)
            }
            Section("Install on the display") {
                Text("Seeed XIAO ESP32-C3 · 7.5-inch · 800 × 480 · OpenDisplay 2.26.5").font(.callout)
                Text("Build includes Wi-Fi image downloads and timed deep sleep. Keep the display connected by USB while flashing.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("USB connection",text:$firmware.port,prompt:Text("Connect the display, then refresh"))
                    Menu("Connections") {
                        ForEach(firmware.ports,id:\.self) { port in Button(port) { firmware.port=port } }
                        Button("Refresh USB connections") { firmware.refreshPorts() }
                    }
                }
                Text("A sleeping display may disappear from this list. Leave its connection selected; flashing will wait for it to wake. You can also press its Reset button.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Build firmware") { Task { await firmware.operate("build",display:display,server:model.settings.serverURL) } }.disabled(firmware.ssid.isEmpty || firmware.password.isEmpty)
                    Button("Flash over USB") { Task { await firmware.operate("flash",display:display,server:model.settings.serverURL);await model.publishAll() } }.disabled(!firmware.canFlash(display.id,model.settings.serverURL))
                }
                Text("Flashing backs up the device, checks its chip and partition layout, and writes only its app partition. Firmware files contain your Wi-Fi credentials and stay in the private local build folder.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Progress") {
                HStack(alignment:.top) {
                    if firmware.working { ProgressView().controlSize(.small) }
                    Text(firmware.status).textSelection(.enabled)
                }
                if let error=firmware.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if !firmware.details.isEmpty { DisclosureGroup("Details") { Text(firmware.details).font(.system(.caption,design:.monospaced)).textSelection(.enabled) } }
            }
            Section("Firmware tools") {
                Text("The app uses your local MacLink source folder and downloads the pinned build tools on first setup.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Source folder") { Text(firmware.sourceFolder).font(.caption).lineLimit(2).textSelection(.enabled) }
                HStack {
                    Button("Choose source folder…") { firmware.chooseFolder() }
                    Button("Prepare build tools") { Task { await firmware.operate("prepare",display:display,server:model.settings.serverURL) } }
                }
            }
        }.formStyle(.grouped).disabled(firmware.working)
            .task(id:display.id) { firmware.load(display.id) }
    }
}
