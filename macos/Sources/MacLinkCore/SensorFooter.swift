import Foundation

public enum SensorTextFormat:String,Codable,CaseIterable,Identifiable {
    case plain,markdown
    public var id:String { rawValue }
    public var label:String { self == .plain ? "Plain text":"Markdown" }
}

public struct SensorFooterItem:Codable,Equatable,Identifiable {
    public var id=UUID().uuidString
    public var entityID:String
    public var label:String
    public var attribute=""
    public var format:SensorTextFormat = .plain
    public var decimals=0
    public var automaticUnit=true
    public var unit=""
    public var onText="On"
    public var offText="Off"
    public init(entityID:String,label:String) { self.entityID=entityID;self.label=label }
}

public struct SensorFooterSettings:Codable,Equatable {
    public var enabled=false
    public var items:[SensorFooterItem]=[]
    public var refreshMinutes=30
    public var lines=1
    public init() {}
    public var visibleItems:[SensorFooterItem] { Array(items.prefix(4)) }
    public var lineCount:Int { min(3,max(1,lines)) }
}

public struct SensorReading:Equatable,Sendable,Identifiable {
    public var id:String
    public var name:String
    public var state:String
    public var attributes:[String:String]
    public init(id:String,name:String,state:String,attributes:[String:String]=[:]) {
        self.id=id;self.name=name;self.state=state;self.attributes=attributes
    }
    public var unavailable:Bool { ["unknown","unavailable"].contains(state) }
}

public struct FooterValue:Equatable {
    public var label:String
    public var text:String
    public var format:SensorTextFormat
    public init(label:String,text:String,format:SensorTextFormat = .plain) { self.label=label;self.text=text;self.format=format }
}

public struct FooterSnapshot:Equatable {
    public var values:[FooterValue]
    public var observedAt:Date?
    public var stale:Bool
    public init(values:[FooterValue]=[],observedAt:Date?=nil,stale:Bool=true) {
        self.values=values;self.observedAt=observedAt;self.stale=stale
    }
}

public enum SensorFormatting {
    public static func value(for item:SensorFooterItem,reading:SensorReading?,locale:Locale = .current) -> FooterValue {
        let label=String(item.label.prefix(80))
        guard let reading else { return FooterValue(label:label,text:"Unavailable") }
        guard !reading.unavailable else { return FooterValue(label:label,text:reading.state == "unknown" ? "Unknown":"Unavailable") }
        let raw:String
        if !item.attribute.isEmpty {
            guard let attribute=reading.attributes[item.attribute] else { return FooterValue(label:label,text:"Unavailable") }
            raw=attribute
        } else if reading.id.hasPrefix("binary_sensor.") {
            raw=reading.state == "on" ? item.onText:(reading.state == "off" ? item.offText:reading.state)
        } else { raw=reading.state }
        var text=String(raw.prefix(4096))
        if let number=Double(raw),number.isFinite {
            let formatter=NumberFormatter();formatter.locale=locale;formatter.numberStyle = .decimal
            formatter.minimumFractionDigits=min(3,max(0,item.decimals));formatter.maximumFractionDigits=formatter.minimumFractionDigits
            formatter.usesGroupingSeparator=false
            text=formatter.string(from:NSNumber(value:number)) ?? text
        }
        let unit=item.automaticUnit ? (item.attribute.isEmpty ? reading.attributes["unit_of_measurement"] ?? "":""):item.unit
        if !unit.isEmpty { text += " \(String(unit.prefix(20)))" }
        return FooterValue(label:label,text:text,format:item.format)
    }
}

public struct FooterSampler {
    private struct Sample {
        var settings:SensorFooterSettings
        var snapshot:FooterSnapshot
        var sampledAt:Date?
    }
    private var samples:[String:Sample]=[:]
    public init() {}
    public mutating func reset() { samples.removeAll() }
    public mutating func snapshot(displayID:String,settings:SensorFooterSettings,readings:[String:SensorReading],connected:Bool,now:Date,force:Bool=false) -> FooterSnapshot {
        guard settings.enabled,!settings.items.isEmpty else { samples.removeValue(forKey:displayID);return FooterSnapshot() }
        let previous=samples[displayID]
        let configurationChanged=previous?.settings != settings
        let elapsed=previous?.sampledAt.map { now.timeIntervalSince($0) } ?? .infinity
        let due=elapsed >= Double(max(1,settings.refreshMinutes))*60 || elapsed<0
        if configurationChanged || (connected && (force || due || previous?.snapshot.stale == true)) {
            let values=settings.visibleItems.map { SensorFormatting.value(for:$0,reading:readings[$0.entityID]) }
            let unchanged = !configurationChanged && previous?.snapshot.values == values && previous?.snapshot.stale == false
            let observedAt=unchanged ? previous?.snapshot.observedAt:(connected ? now:nil)
            samples[displayID]=Sample(settings:settings,snapshot:FooterSnapshot(values:values,observedAt:observedAt,stale:!connected),sampledAt:connected ? now:nil)
        }
        guard var sample=samples[displayID] else { return FooterSnapshot() }
        if !connected,!sample.snapshot.stale { sample.snapshot.observedAt=sample.sampledAt }
        sample.snapshot.stale = !connected
        samples[displayID]=sample
        return sample.snapshot
    }
}

public struct MarkdownSpan:Equatable {
    public var text:String
    public var bold:Bool
    public init(text:String,bold:Bool=false) { self.text=text;self.bold=bold }
}

public enum FooterMarkdown {
    public static func spans(_ text:String,format:SensorTextFormat) -> [MarkdownSpan] {
        let bounded=String(text.prefix(4096))
        guard format == .markdown,let parsed=try? AttributedString(markdown:bounded,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace)) else {
            return [MarkdownSpan(text:bounded)]
        }
        return parsed.runs.map { run in
            let intent=run.inlinePresentationIntent ?? []
            return MarkdownSpan(text:String(parsed[run.range].characters),bold:intent.contains(.stronglyEmphasized) || intent.contains(.emphasized))
        }
    }
}
