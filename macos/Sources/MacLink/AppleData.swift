import AppKit
import EventKit
import MacLinkCore

@MainActor
final class AppleData: ObservableObject {
    let store = EKEventStore()
    @Published var calendars: [EKCalendar] = []
    @Published var lists: [EKCalendar] = []
    @Published var calendarGranted = false
    @Published var remindersGranted = false
    @Published var error: String?

    func reloadSources() {
        calendarGranted = EKEventStore.authorizationStatus(for:.event) == .fullAccess
        remindersGranted = EKEventStore.authorizationStatus(for:.reminder) == .fullAccess
        calendars = calendarGranted ? store.calendars(for:.event).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : []
        lists = remindersGranted ? store.calendars(for:.reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : []
    }

    func requestCalendars() async {
        do { _ = try await store.requestFullAccessToEvents() }
        catch { self.error = error.localizedDescription }
        reloadSources()
    }
    func requestReminders() async {
        do { _ = try await store.requestFullAccessToReminders() }
        catch { self.error = error.localizedDescription }
        reloadSources()
    }

    func snapshot(settings: DisplaySettings, now: Date) async throws -> ([AgendaItem],[TaskGroup]) {
        reloadSources()
        if !settings.calendarIDs.isEmpty && !calendarGranted { throw DataError("Calendar access is unavailable. Allow access in System Settings.") }
        if !settings.reminderLists.isEmpty && !remindersGranted { throw DataError("Reminders access is unavailable. Allow access in System Settings.") }
        let selected=calendars.filter { settings.calendarIDs.contains($0.calendarIdentifier) }
        if selected.count != settings.calendarIDs.count { throw DataError("A selected calendar is no longer available. Review your selection.") }
        let range=DashboardRules.interval(now:now,days:settings.effectiveCalendarDays,calendar:.current)
        let events: [AgendaItem] = selected.isEmpty ? [] : store.events(matching:store.predicateForEvents(withStart:range.start,end:range.end,calendars:selected))
            .filter { $0.status != .canceled && $0.endDate > range.start }
            .map { AgendaItem(id:$0.eventIdentifier ?? UUID().uuidString,title:$0.title ?? "Untitled event",start:$0.startDate,end:$0.endDate,allDay:$0.isAllDay,calendarName:$0.calendar.title,calendarID:$0.calendar.calendarIdentifier,location:$0.location ?? "") }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var groups: [TaskGroup] = []
        for selection in settings.reminderLists {
            guard let list=lists.first(where:{$0.calendarIdentifier==selection.id}) else { throw DataError("A selected reminder list is no longer available. Review your selection.") }
            let predicate=store.predicateForIncompleteReminders(withDueDateStarting:nil,ending:nil,calendars:[list])
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching:predicate) { continuation.resume(returning:$0 ?? []) }
            }
            let tasks=reminders.filter { !$0.isCompleted && (settings.includeUndated || $0.dueDateComponents != nil) }.map { reminder in
                var dateComponents=reminder.dueDateComponents
                if dateComponents?.calendar == nil { dateComponents?.calendar = Calendar.current }
                return TaskItem(id:reminder.calendarItemIdentifier,title:reminder.title ?? "Untitled reminder",due:dateComponents?.date,dateOnly:dateComponents?.hour == nil,priority:reminder.priority,created:reminder.creationDate,modified:reminder.lastModifiedDate)
            }
            groups.append(TaskGroup(name:list.title,items:DashboardRules.sorted(tasks,by:selection)))
        }
        return (events,groups)
    }
}
