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
    @Published private(set) var readings:[String:SensorReading]=[:]
    @Published private(set) var ready=false
    @Published private(set) var connecting=false
    @Published private(set) var status="Not connected"
    @Published private(set) var problem:String?
    var availabilityChanged:(() -> Void)?
    private var connection:HAConnection?
    private var subscription:HACancellable?
    private var timeout:Task<Void,Never>?
    private var generation=UUID()

    var sensors:[SensorReading] {
        readings.values.sorted {
            let order=$0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id<$1.id:order == .orderedAscending
        }
    }

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
        let current=generation
        let client=HAKit.connection(configuration:.init(connectionInfo:{ try? .init(url:url) },fetchAuthToken:{ completion in completion(.success(token)) }),connectAutomatically:false)
        connection=client;client.delegate=self
        subscription=client.caches.states().subscribe { [weak self,weak client] _,states in
            Task { @MainActor in
                guard let self,let client,self.generation==current,case .ready = client.state else { return }
                var result:[String:SensorReading]=[:]
                for entity in states.all where entity.domain == "sensor" || entity.domain == "binary_sensor" {
                    var attributes:[String:String]=[:]
                    for (key,value) in entity.attributes.dictionary {
                        if let value=value as? String { attributes[key]=String(value.prefix(4096)) }
                        else if let value=value as? NSNumber { attributes[key]=value.stringValue }
                    }
                    result[entity.entityId]=SensorReading(id:entity.entityId,name:entity.attributes.friendlyName ?? entity.entityId,state:entity.state,attributes:attributes)
                }
                self.readings=result;self.connecting=false;self.problem=nil
                self.status="Connected · \(result.count) sensors";self.timeout?.cancel()
                self.setReady(true)
            }
        }
        client.connect()
        armTimeout()
    }

    func stop(clear:Bool=false) {
        generation=UUID();timeout?.cancel();timeout=nil
        subscription?.cancel();subscription=nil
        connection?.delegate=nil;connection?.disconnect();connection=nil
        connecting=false;status="Disconnected";problem=nil
        if clear { readings=[:] }
        setReady(false)
    }

    func checkConnection() { connection?.connect() }

    nonisolated func connection(_ connection:HAConnection,didTransitionTo state:HAConnectionState) {
        Task { @MainActor [weak self] in
            guard let self,self.connection === connection else { return }
            switch state {
            case .ready:
                self.status="Loading sensors…";self.connecting=true;self.armTimeout()
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
