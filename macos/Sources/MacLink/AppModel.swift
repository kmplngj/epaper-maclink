import AppKit
import Combine
import EventKit
import MacLinkCore
import ServiceManagement

struct SavedSettings: Codable {
    var serverURL="http://localhost:8099"
    var displays:[DisplaySettings]=[]
    var homeAssistant:HomeAssistantSettings?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings=SavedSettings()
    @Published var selectedID:String?
    @Published var accessToken=""
    @Published var remote:[RemoteDisplay]=[]
    @Published var preview:NSImage?
    @Published var message="Connect your home server to get started."
    @Published var error:String?
    @Published var working=false
    @Published var connected=false
    @Published var lastPublished:Date?
    @Published var launchAtLogin=false
    let apple=AppleData()
    let firmware=FirmwareSetup()
    let homeAssistant=HomeAssistant()
    private var footerSampler=FooterSampler()
    private var observers:[NSObjectProtocol]=[]
    private var watchedSensors:AnyCancellable?
    private var debounce:Task<Void,Never>?
    private var running=false
    private var connecting=false
    private var dirty=false
    private let background=NSBackgroundActivityScheduler(identifier:"de.maclink.reconcile")
    private var boundaryTimer:Timer?
    private var frames:[String:RenderedFrame]=[:]
    private var hashes:[String:String]=[:]
    let directory:URL

    init() {
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MacLink")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:directory.appendingPathComponent("settings.json")),let saved=try? JSONDecoder().decode(SavedSettings.self,from:data) { settings=saved }
        accessToken=Keychain.get("server-admin")
        let bootstrap=directory.appendingPathComponent("bootstrap.json")
        if let data=try? Data(contentsOf:bootstrap),let object=try? JSONSerialization.jsonObject(with:data) as? [String:String] {
            if let url=object["serverURL"] { settings.serverURL=url }
            if let token=object["token"],accessToken.isEmpty {
                do { try Keychain.set("server-admin",token);accessToken=token;try? FileManager.default.removeItem(at:bootstrap) }
                catch { self.error="Couldn't save the server credential in Keychain." }
            } else if !accessToken.isEmpty { try? FileManager.default.removeItem(at:bootstrap) }
        }
        selectedID=settings.displays.first?.id
        apple.reloadSources()
        launchAtLogin=SMAppService.mainApp.status == .enabled
        observers.append(NotificationCenter.default.addObserver(forName:.EKEventStoreChanged,object:apple.store,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.apple.reloadSources();self?.schedule() }
        })
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.schedule() } })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSNotification.Name.NSSystemTimeZoneDidChange,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.schedule() } })
        background.interval=15*60;background.tolerance=3*60;background.repeats=true;background.qualityOfService = .utility
        background.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion(.finished);return }
                await self.publishAll();completion(.finished)
            }
        }
        // A coalescible boundary check drives event transitions; unchanged pixels never upload.
        boundaryTimer=Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in Task { @MainActor in self?.schedule() } }
        boundaryTimer?.tolerance=10
        homeAssistant.availabilityChanged = { [weak self] in self?.schedule() }
        watchedSensors=$settings.map { Set($0.displays.flatMap { $0.footer.items.map(\.entityID) }) }.removeDuplicates()
            .sink { [weak self] in self?.homeAssistant.watch($0) }
        if let config=settings.homeAssistant,config.enabled,let url=try? HomeAssistant.validatedURL(config.url) {
            let token=Keychain.get("home-assistant")
            if !token.isEmpty { homeAssistant.start(url:url,token:token) }
        }
        if !accessToken.isEmpty { Task { await connect() } }
    }

    var current:DisplaySettings? { settings.displays.first { $0.id==selectedID } }
    var client:ServerClient { ServerClient(base:settings.serverURL,token:accessToken) }

    func connectHomeAssistant(url:String,token:String) throws {
        let address=try HomeAssistant.validatedURL(url)
        let credential=token.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !credential.isEmpty else { throw DataError("Enter a Home Assistant long-lived access token.") }
        try Keychain.set("home-assistant",credential)
        settings.homeAssistant=HomeAssistantSettings(url:address.absoluteString,enabled:true)
        footerSampler.reset();save();homeAssistant.start(url:address,token:credential);schedule()
    }

    func disconnectHomeAssistant() {
        settings.homeAssistant?.enabled=false;save();homeAssistant.stop();schedule()
    }

    func checkForChanges() async {
        homeAssistant.checkConnection()
        await publishAll(refreshSensors:true)
    }

    func save() {
        do { let data=try JSONEncoder().encode(settings);try data.write(to:directory.appendingPathComponent("settings.json"),options:.atomic) }
        catch { self.error="Couldn't save settings: \(error.localizedDescription)" }
    }

    func update(_ value:DisplaySettings) {
        guard let index=settings.displays.firstIndex(where:{$0.id==value.id}) else { return }
        var edited=value
        edited.lastRevision=settings.displays[index].lastRevision
        settings.displays[index]=edited;save();schedule()
    }

    func select(_ id:String?) { guard !firmware.working else { return };selectedID=id;preview=id.flatMap { frames[$0]?.image };schedule() }

    func connect() async {
        guard !connecting else { return }
        connecting=true;working=true;error=nil
        defer { connecting=false;working=false }
        do {
            try Keychain.set("server-admin",accessToken)
            let list:[RemoteDisplay]=try await client.request("/v1/displays")
            remote=list
            for item in list {
                if let index=settings.displays.firstIndex(where:{$0.id==item.id}) {
                    settings.displays[index].lastRevision=max(settings.displays[index].lastRevision,item.revision)
                    applyBattery(item,index:index)
                } else {
                    var entry=DisplaySettings(id:item.id,name:item.name);entry.width=item.width;entry.height=item.height;entry.pollSeconds=item.poll_seconds;entry.lastRevision=item.revision
                    settings.displays.append(entry)
                    applyBattery(item,index:settings.displays.count-1)
                }
                if let digest=item.digest { hashes[item.id]=digest }
            }
            connected=true;message="Connected to your home server."
            if selectedID==nil { selectedID=settings.displays.first?.id }
            save();await publishAll()
        } catch { connected=false;self.error=error.localizedDescription }
    }

    func addDisplay(name:String) async {
        guard !firmware.working else { return }
        working=true;error=nil
        defer { working=false }
        do {
            let body=try JSONSerialization.data(withJSONObject:["name":name,"width":800,"height":480])
            let created:CreatedDisplay=try await client.request("/v1/displays",method:"POST",body:body)
            try Keychain.set("display-\(created.display.id)",created.device_token)
            settings.displays.append(DisplaySettings(id:created.display.id,name:created.display.name))
            remote.append(created.display);selectedID=created.display.id;save();schedule()
        } catch { self.error=error.localizedDescription }
    }

    private func applyBattery(_ item:RemoteDisplay,index:Int) {
        settings.displays[index].pollSeconds=item.poll_seconds
        settings.displays[index].scheduleEnabled=item.schedule_enabled ?? false
        settings.displays[index].updateStart=item.update_start ?? 7*60
        settings.displays[index].updateEnd=item.update_end ?? 22*60
        if let zone=item.schedule_timezone { settings.displays[index].scheduleTimezone=zone }
    }

    func saveBattery(_ value:DisplaySettings) async throws {
        let body=try JSONSerialization.data(withJSONObject:["poll_seconds":value.pollSeconds,"schedule_enabled":value.scheduleEnabled,"update_start":value.updateStart,"update_end":value.updateEnd,"schedule_timezone":value.scheduleTimezone])
        let response:RemoteDisplay=try await client.request("/v1/displays/\(value.id)/battery",method:"PATCH",body:body)
        if let index=settings.displays.firstIndex(where:{$0.id==value.id}) { applyBattery(response,index:index);save() }
        if let index=remote.firstIndex(where:{$0.id==value.id}) { remote[index]=response }
    }

    func setLogin(_ enabled:Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin=SMAppService.mainApp.status == .enabled
        } catch { self.error="Couldn't change launch at login: \(error.localizedDescription)" }
    }

    func schedule() {
        debounce?.cancel()
        debounce=Task { try? await Task.sleep(for:.seconds(2));guard !Task.isCancelled else { return };await publishAll() }
    }

    func publishAll(force:Bool=false,refreshSensors:Bool=false) async {
        if !connected && !accessToken.isEmpty { await connect();return }
        if running { dirty=true;return }
        running=true;working=true
        defer { running=false;working=false;if dirty { dirty=false;schedule() } }
        error=nil
        let now=Date()
        for original in settings.displays where original.enabled {
            do {
                let (events,groups)=try await apple.snapshot(settings:original,now:now)
                guard let index=settings.displays.firstIndex(where:{$0.id==original.id}),settings.displays[index]==original else { dirty=true;continue }
                let footer=footerSampler.snapshot(displayID:original.id,settings:original.footer,readings:homeAssistant.readings,connected:homeAssistant.ready,now:now,force:refreshSensors)
                let frame=try DashboardRenderer.render(settings:original,events:events,groups:groups,now:now,footer:footer)
                frames[original.id]=frame
                if selectedID==original.id { preview=frame.image }
                try frame.png.write(to:directory.appendingPathComponent("\(original.id).png"),options:.atomic)
                guard connected else { message="Preview ready. Connect your server to publish.";continue }
                if !force && hashes[original.id]==frame.pixelHash { message="Up to date · unchanged pixels skipped";continue }
                let revision=max(original.lastRevision+1,Int64(Date().timeIntervalSince1970*1000))
                settings.displays[index].lastRevision=revision;save()
                let response:PublishedDisplay=try await client.request("/v1/displays/\(original.id)/image",method:"PUT",body:frame.png,headers:["Content-Type":"image/png","X-Revision":String(revision),"X-Observed-At":ISO8601DateFormatter().string(from:now)])
                guard response.display.digest==frame.pixelHash else { throw DataError("Server pixel verification failed. The preview was not marked as delivered.") }
                hashes[original.id]=frame.pixelHash;lastPublished=Date()
                if let ri=remote.firstIndex(where:{$0.id==original.id}) { remote[ri]=response.display }
                message=response.changed ? "Published \(original.name) · waiting for display":"Up to date · unchanged pixels skipped"
            } catch { self.error=error.localizedDescription }
        }
        if connected {
            do { remote=try await client.request("/v1/displays") }
            catch { self.error="Can't reach the server. Your preview and pending changes are kept locally." }
        }
    }
}
