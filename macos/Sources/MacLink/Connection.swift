import Foundation
import Security

enum Keychain {
    static func get(_ account:String) -> String {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"de.maclink.app",kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func set(_ account:String,_ value:String) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"de.maclink.app",kSecAttrAccount as String:account]
        let data=Data(value.utf8)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var item=query;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result=SecItemAdd(item as CFDictionary,nil)
            guard result==errSecSuccess else { throw DataError("Couldn't save the access token in Keychain (\(result)).") }
        } else if status != errSecSuccess { throw DataError("Couldn't update Keychain (\(status)).") }
    }
}

struct RemoteDisplay: Codable,Identifiable {
    let id:String
    var name:String
    let width:Int
    let height:Int
    let revision:Int64
    let digest:String?
    let delivered_digest:String?
    let delivered_at:String?
    let last_seen:String?
    let poll_seconds:Int
    let schedule_enabled:Bool?
    let update_start:Int?
    let update_end:Int?
    let schedule_timezone:String?
}
struct CreatedDisplay: Decodable { let display:RemoteDisplay;let device_token:String }
struct PublishedDisplay: Decodable { let changed:Bool;let display:RemoteDisplay }

struct ServerClient {
    let base:String
    let token:String
    func request<T:Decodable>(_ path:String,method:String="GET",body:Data?=nil,headers:[String:String]=[:]) async throws -> T {
        guard let baseURL=URL(string:base),["http","https"].contains(baseURL.scheme),baseURL.host != nil,
              let url=URL(string:base.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+path) else { throw DataError("Enter a valid server URL.") }
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body;request.timeoutInterval=25
        request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse else { throw DataError("The server returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode==401 { throw DataError("Server access was denied. Check your access token.") }
            if response.statusCode==409 { throw DataError("A newer image is on the server. Reconnect and publish again.") }
            throw DataError("Server request failed (\(response.statusCode)).")
        }
        return try JSONDecoder().decode(T.self,from:data)
    }
}
