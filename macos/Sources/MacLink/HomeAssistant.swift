import Foundation
import Combine
import HAKit
import MacLinkCore

struct HomeAssistantSettings:Codable {
    var url=""
    var enabled=false
}

@MainActor
final class HomeAssistant:ObservableObject,HAConnectionDelegate {
    /// Readings for watched entities only; the footer never needs the rest of Home Assistant.
    @Published private(set) var readings:[String:SensorReading]=[:]
    /// Every sensor, fetched once while the picker is open. Nil until loaded.
    @Published private(set) var catalog:[SensorReading]?
    @Published private(set) var catalogProblem:String?
    @Published private(set) var ready=false
    @Published private(set) var connecting=false
    @Published private(set) var status="Not connected"
    @Published private(set) var problem:String?
    var availabilityChanged:(() -> Void)?
    private var connection:HAConnection?
    private var subscription:HACancellable?
    private var catalogRequest:HACancellable?
    private var timeout:Task<Void,Never>?
    private var flush:Task<Void,Never>?
    private var pending:HACachedStates?
    private var watched:Set<String>=[]
    private var generation=UUID()

    static func validatedURL(_ text:String) throws -> URL {
        guard let url=URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              ["http","https"].contains(url.scheme),let host=url.host,!host.isEmpty,
              url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,
              url.port.map({(1...65535).contains($0)}) ?? true else {
            throw DataError("Enter the Home Assistant address, such as http://homeassistant.local:8123, without credentials or query parameters.")
        }
        return url
    }

    func start(url:URL,token:String) {
        stop(clear:true)
        problem=nil;status="Connecting…";connecting=true
        let client=HAKit.connection(configuration:.init(connectionInfo:{ try? .init(url:url) },fetchAuthToken:{ completion in completion(.success(token)) }),connectAutomatically:false)
        connection=client;client.delegate=self
        subscribe()
        client.connect()
        armTimeout()
    }

    func stop(clear:Bool=false) {
        generation=UUID();timeout?.cancel();timeout=nil
        flush?.cancel();flush=nil;pending=nil
        subscription?.cancel();subscription=nil
        releaseCatalog()
        connection?.delegate=nil;connection?.disconnect();connection=nil
        connecting=false;status="Disconnected";problem=nil
        if clear { readings=[:] }
        setReady(false)
    }

    func checkConnection() { connection?.connect() }

    /// Limits the live subscription to these entities, resubscribing only when the set changes.
    func watch(_ entityIDs:Set<String>) {
        guard entityIDs != watched else { return }
        watched=entityIDs
        if connection != nil { subscribe() }
    }

    /// Makes a reading picked from the catalog available before its subscription delivers.
    func seed(_ reading:SensorReading) { readings[reading.id]=reading }

    func loadCatalog() {
        guard let client=connection,catalogRequest==nil else { return }
        catalogProblem=nil
        catalogRequest=client.send(HATypedRequest<[HAEntity]>(request:.init(type:.getStates))) { [weak self,weak client] result in
            Task { @MainActor in
                guard let self,let client,self.connection === client else { return }
                self.catalogRequest=nil
                switch result {
                case .success(let entities):
                    self.catalog=entities.filter(Self.isSensor).map(Self.reading).sorted {
                        let order=$0.name.localizedStandardCompare($1.name)
                        return order == .orderedSame ? $0.id<$1.id:order == .orderedAscending
                    }
                case .failure:
                    self.catalogProblem="Couldn't load sensors from Home Assistant. Check the connection, then try again."
                }
            }
        }
    }

    func releaseCatalog() {
        catalogRequest?.cancel();catalogRequest=nil
        catalog=nil;catalogProblem=nil
    }

    private func subscribe() {
        generation=UUID();flush?.cancel();flush=nil;pending=nil
        subscription?.cancel();subscription=nil
        guard let client=connection else { return }
        readings=readings.filter { watched.contains($0.key) }
        guard !watched.isEmpty else {
            if case .ready = client.state { markLoaded() }
            return
        }
        // An empty entity_ids list would subscribe to every entity, hence the guard above.
        let cache=client.caches.states(["entity_ids":watched.sorted()])
        cache.shouldResetWithoutSubscribers=true
        let current=generation
        subscription=cache.subscribe { [weak self] _,states in
            Task { @MainActor in self?.receive(states,generation:current) }
        }
    }

    private func receive(_ states:HACachedStates,generation current:UUID) {
        guard generation==current,let client=connection,case .ready = client.state else { return }
        pending=states
        // The first value unblocks rendering at once; later bursts collapse into one update.
        if !ready { apply();return }
        guard flush==nil else { return }
        flush=Task { [weak self] in
            try? await Task.sleep(for:.seconds(2))
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        flush=nil
        guard let states=pending else { return }
        pending=nil
        var result:[String:SensorReading]=[:]
        for id in watched { if let entity=states[id] { result[id]=Self.reading(entity) } }
        if result != readings { readings=result }
        markLoaded()
    }

    private func markLoaded() {
        connecting=false;problem=nil;timeout?.cancel()
        status=watched.isEmpty ? "Connected":"Connected · \(readings.count) of \(watched.count) sensors"
        setReady(true)
    }

    private static func isSensor(_ entity:HAEntity) -> Bool { entity.domain == "sensor" || entity.domain == "binary_sensor" }

    private static func reading(_ entity:HAEntity) -> SensorReading {
        var attributes:[String:String]=[:]
        for (key,value) in entity.attributes.dictionary {
            if let value=value as? String { attributes[key]=String(value.prefix(4096)) }
            else if let value=value as? NSNumber { attributes[key]=value.stringValue }
        }
        return SensorReading(id:entity.entityId,name:entity.attributes.dictionary["friendly_name"] as? String ?? entity.entityId,state:entity.state,attributes:attributes)
    }

    nonisolated func connection(_ connection:HAConnection,didTransitionTo state:HAConnectionState) {
        Task { @MainActor [weak self] in
            guard let self,self.connection === connection else { return }
            switch state {
            case .ready:
                if self.watched.isEmpty { self.markLoaded() }
                else { self.status="Loading sensors…";self.connecting=true;self.armTimeout() }
            case .connecting,.authenticating:
                self.setReady(false);self.connecting=true;self.status="Connecting…";self.armTimeout()
            case .disconnected(let reason):
                self.timeout?.cancel();self.connecting=false;self.setReady(false)
                switch reason {
                case .rejected:
                    self.status="Access denied"
                    self.problem="Home Assistant rejected the token. Create a long-lived access token in your Home Assistant profile, then reconnect."
                case .waitingToReconnect:
                    self.status="Offline · reconnecting"
                    self.problem="Can't reach Home Assistant. Check its address and your network. Last sampled values remain marked as stale."
                case .disconnected: self.status="Disconnected"
                }
            }
        }
    }

    private func setReady(_ value:Bool) {
        guard ready != value else { return }
        ready=value;availabilityChanged?()
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(20))
            guard !Task.isCancelled,let self,!self.ready else { return }
            self.connecting=false
            self.problem="No sensor data received. Check the address, token and Home Assistant connection, then retry."
        }
    }
}
