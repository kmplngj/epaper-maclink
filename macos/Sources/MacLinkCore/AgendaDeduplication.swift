import Foundation

public struct AgendaSource: Hashable {
    public let id:String
    public let name:String
}

public struct AgendaEntry {
    public let event:AgendaItem
    public var sources:[AgendaSource]
}

public enum AgendaDeduplication {
    private struct Key:Hashable {
        let title:String
        let start:Date
        let end:Date
        let allDay:Bool
        let location:String
    }
    private static func normalized(_ value:String)->String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
            .lowercased()
    }
    /// Merge matching occurrences across calendars, preserving their sources.
    /// Separate occurrences within one calendar remain separate entries.
    public static func merge(_ events:[AgendaItem])->[AgendaEntry] {
        var result:[AgendaEntry]=[],indices:[Key:[Int]]=[:]
        let ordered=events.sorted { a,b in
            if a.start != b.start { return a.start<b.start }
            if a.title != b.title { return a.title<b.title }
            if a.end != b.end { return a.end<b.end }
            if a.calendarID != b.calendarID { return a.calendarID<b.calendarID }
            return a.id<b.id
        }
        for event in ordered {
            let key=Key(title:normalized(event.title),start:event.start,end:event.end,allDay:event.allDay,location:normalized(event.location))
            let source=AgendaSource(id:event.calendarID,name:event.calendarName)
            let sameCalendar:(AgendaSource)->Bool = { existing in
                source.id.isEmpty ? existing.id.isEmpty && existing.name==source.name : existing.id==source.id
            }
            if let index=indices[key]?.first(where:{ !result[$0].sources.contains(where:sameCalendar) }) {
                result[index].sources.append(source)
            } else {
                indices[key,default:[]].append(result.count)
                result.append(AgendaEntry(event:event,sources:[source]))
            }
        }
        return result
    }
}
