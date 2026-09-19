import Foundation

public enum ReminderSort: String, Codable, CaseIterable, Identifiable {
    case dueDate, priority, title, created, modified
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .title: return "Title"
        case .created: return "Date created"
        case .modified: return "Last modified"
        }
    }
}

public struct ReminderListSelection: Codable, Equatable, Identifiable {
    public var id: String
    public var sort: ReminderSort = .dueDate
    public var ascending = true
    public init(id: String) { self.id = id }
}

public struct DisplaySettings: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var width = 800
    public var height = 480
    public var calendarDays = 7
    public var calendarIDs: Set<String> = []
    public var calendarAbbreviations: [String:String] = [:]
    public var autoFitDays = true
    public var reminderLists: [ReminderListSelection] = []
    public var includeUndated = true
    public var enabled = true
    public var lastRevision: Int64 = 0
    public var pollSeconds = 300
    public var scheduleEnabled = false
    public var updateStart = 7*60
    public var updateEnd = 22*60
    public var scheduleTimezone = TimeZone.current.identifier
    public var footer = SensorFooterSettings()
    public init(id: String, name: String) { self.id=id; self.name=name }
    public var effectiveCalendarDays:Int { autoFitDays ? 31:calendarDays }
    public func abbreviation(for id:String,name:String) -> String {
        if let configured=calendarAbbreviations[id] { return String(configured.trimmingCharacters(in:.whitespacesAndNewlines).prefix(6)) }
        return String(name.prefix(3)).uppercased()
    }
    private enum CodingKeys:String,CodingKey { case id,name,width,height,calendarDays,calendarIDs,calendarAbbreviations,autoFitDays,reminderLists,includeUndated,enabled,lastRevision,pollSeconds,scheduleEnabled,updateStart,updateEnd,scheduleTimezone,footer }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        width=try c.decodeIfPresent(Int.self,forKey:.width) ?? 800
        height=try c.decodeIfPresent(Int.self,forKey:.height) ?? 480
        calendarDays=try c.decodeIfPresent(Int.self,forKey:.calendarDays) ?? 7
        calendarIDs=try c.decodeIfPresent(Set<String>.self,forKey:.calendarIDs) ?? []
        calendarAbbreviations=try c.decodeIfPresent([String:String].self,forKey:.calendarAbbreviations) ?? [:]
        autoFitDays=try c.decodeIfPresent(Bool.self,forKey:.autoFitDays) ?? true
        reminderLists=try c.decodeIfPresent([ReminderListSelection].self,forKey:.reminderLists) ?? []
        includeUndated=try c.decodeIfPresent(Bool.self,forKey:.includeUndated) ?? true
        enabled=try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? true
        lastRevision=try c.decodeIfPresent(Int64.self,forKey:.lastRevision) ?? 0
        pollSeconds=try c.decodeIfPresent(Int.self,forKey:.pollSeconds) ?? 300
        scheduleEnabled=try c.decodeIfPresent(Bool.self,forKey:.scheduleEnabled) ?? false
        updateStart=try c.decodeIfPresent(Int.self,forKey:.updateStart) ?? 7*60
        updateEnd=try c.decodeIfPresent(Int.self,forKey:.updateEnd) ?? 22*60
        scheduleTimezone=try c.decodeIfPresent(String.self,forKey:.scheduleTimezone) ?? TimeZone.current.identifier
        footer=try c.decodeIfPresent(SensorFooterSettings.self,forKey:.footer) ?? SensorFooterSettings()
    }
}

public struct AgendaItem: Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendarName: String
    public var calendarID: String
    public var location: String
    public init(id: String,title: String,start: Date,end: Date,allDay: Bool,calendarName: String,calendarID:String="",location:String="") {
        self.id=id;self.title=title;self.start=start;self.end=end;self.allDay=allDay;self.calendarName=calendarName
        self.calendarID=calendarID
        self.location=location
    }
}

public struct TaskItem: Identifiable {
    public var id: String
    public var title: String
    public var due: Date?
    public var dateOnly: Bool
    public var priority: Int
    public var created: Date?
    public var modified: Date?
    public init(id: String,title: String,due: Date?,dateOnly: Bool=false,priority: Int=0,created: Date?=nil,modified: Date?=nil) {
        self.id=id;self.title=title;self.due=due;self.dateOnly=dateOnly;self.priority=priority;self.created=created;self.modified=modified
    }
}

public struct TaskGroup {
    public var name: String
    public var items: [TaskItem]
    public init(name: String,items: [TaskItem]) { self.name=name;self.items=items }
}

public enum DashboardRules {
    public static func interval(now: Date, days: Int, calendar: Calendar) -> DateInterval {
        let start=calendar.startOfDay(for: now)
        return DateInterval(start:start,end:calendar.date(byAdding:.day,value:days,to:start)!)
    }

    public static func sorted(_ tasks:[TaskItem],by rule: ReminderListSelection) -> [TaskItem] {
        tasks.sorted { a,b in
            let comparison: ComparisonResult
            switch rule.sort {
            case .dueDate: comparison = compareOptional(a.due,b.due)
            case .created: comparison = compareOptional(a.created,b.created)
            case .modified: comparison = compareOptional(a.modified,b.modified)
            case .priority:
                let av=a.priority==0 ? 10:a.priority, bv=b.priority==0 ? 10:b.priority
                comparison=av==bv ? .orderedSame : (av<bv ? .orderedAscending:.orderedDescending)
            case .title: comparison=a.title.localizedStandardCompare(b.title)
            }
            if comparison == .orderedSame {
                let t=a.title.localizedStandardCompare(b.title)
                return t == .orderedSame ? a.id < b.id : t == .orderedAscending
            }
            // Missing dates always remain last, independently of direction.
            if rule.sort == .dueDate && (a.due == nil || b.due == nil) { return a.due != nil }
            if rule.sort == .created && (a.created == nil || b.created == nil) { return a.created != nil }
            if rule.sort == .modified && (a.modified == nil || b.modified == nil) { return a.modified != nil }
            return rule.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compareOptional(_ a:Date?,_ b:Date?) -> ComparisonResult {
        switch (a,b) {
        case let (a?,b?): return a.compare(b)
        case (nil,nil): return .orderedSame
        case (nil,_): return .orderedDescending
        default: return .orderedAscending
        }
    }
}
