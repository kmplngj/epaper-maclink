#if canImport(XCTest)
import XCTest
@testable import MacLinkCore
#else
import Foundation
class XCTestCase {}
func XCTAssertEqual<T:Equatable>(_ a:T,_ b:T) { precondition(a==b, "Expected \(b), got \(a)") }
#endif

final class RulesTests:XCTestCase {
    func testSevenDaysAcrossDaylightSavingBoundary() {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Europe/Berlin")!
        let date=ISO8601DateFormatter().date(from:"2026-10-24T12:00:00Z")!
        let settings=DisplaySettings(id:"x",name:"Desk")
        XCTAssertEqual(settings.calendarDays,7)
        let range=DashboardRules.interval(now:date,days:settings.calendarDays,calendar:calendar)
        XCTAssertEqual(calendar.dateComponents([.day],from:range.start,to:range.end).day,7)
        XCTAssertEqual(range.duration,7*86400+3600)
    }
    func testIndependentListSortingAndUndatedLast() {
        let items=[TaskItem(id:"a",title:"Zebra",due:nil,priority:0),TaskItem(id:"b",title:"Apple",due:Date(timeIntervalSince1970:200),priority:5),TaskItem(id:"c",title:"Carrot",due:Date(timeIntervalSince1970:100),priority:1)]
        var selection=ReminderListSelection(id:"x")
        XCTAssertEqual(DashboardRules.sorted(items,by:selection).map(\.id),["c","b","a"])
        selection.ascending=false
        XCTAssertEqual(DashboardRules.sorted(items,by:selection).map(\.id),["b","c","a"])
        selection.sort = .priority;selection.ascending=true
        XCTAssertEqual(DashboardRules.sorted(items,by:selection).map(\.id),["c","b","a"])
        selection.sort = .title
        XCTAssertEqual(DashboardRules.sorted(items,by:selection).map(\.id),["b","c","a"])
    }
    func testSettingsRoundTripPreservesPerDisplaySelections() throws {
        var first=DisplaySettings(id:"desk",name:"Desk");first.calendarIDs=["work"];first.reminderLists=[ReminderListSelection(id:"tasks")]
        first.pollSeconds=1800;first.scheduleEnabled=true;first.updateStart=420;first.updateEnd=1320;first.scheduleTimezone="Europe/Berlin"
        var second=DisplaySettings(id:"hall",name:"Hall");second.calendarIDs=["family"];second.reminderLists=[ReminderListSelection(id:"shopping")];second.reminderLists[0].sort = .title
        second.pollSeconds=3600;second.scheduleEnabled=true;second.updateStart=1320;second.updateEnd=360;second.scheduleTimezone="America/New_York"
        let data=try JSONEncoder().encode([first,second])
        XCTAssertEqual(try JSONDecoder().decode([DisplaySettings].self,from:data),[first,second])
    }
    func testExistingSettingsMigrationAndAbbreviations() throws {
        let old=Data(#"{"id":"desk","name":"Desk","calendarIDs":["family"],"calendarDays":7,"reminderLists":[{"id":"tasks","sort":"priority","ascending":false}]}"#.utf8)
        var decoded=try JSONDecoder().decode(DisplaySettings.self,from:old)
        XCTAssertEqual(decoded.calendarIDs,["family"])
        XCTAssertEqual(decoded.reminderLists.first?.sort,.priority)
        XCTAssertEqual(decoded.reminderLists.first?.ascending,false)
        XCTAssertEqual(decoded.abbreviation(for:"family",name:"Family"),"FAM")
        decoded.calendarAbbreviations["family"]="KIDS"
        let restored=try JSONDecoder().decode(DisplaySettings.self,from:JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.abbreviation(for:"family",name:"Family"),"KIDS")
        decoded.calendarAbbreviations["family"]=""
        XCTAssertEqual(decoded.abbreviation(for:"family",name:"Family"),"")
    }
    func testVariableDayPackingNeverDropsEntriesFromDisplayedDays() {
        let rows=[[20],[20,20,20,20,20,20],[20],[20,20,20]]
        let fit=AgendaPacking.fit(dayRows:rows,laneStarts:[0,40],bottom:140,gap:5)
        XCTAssertEqual(fit.completeDays,3)
        for day in 0..<fit.completeDays { XCTAssertEqual(fit.placements.filter {$0.day==day}.map(\.row),Array(rows[day].indices)) }
        XCTAssertEqual(fit.placements.contains {$0.day==3},false)
        XCTAssertEqual(fit.placements.allSatisfy {$0.y+rows[$0.day][$0.row]<=140},true)
    }
    func testOneBusyDayCanContinueAcrossColumnsWithoutOmission() {
        let fit=AgendaPacking.fit(dayRows:[Array(repeating:20,count:9),[20]],laneStarts:[0,20],bottom:120)
        XCTAssertEqual(fit.completeDays,2)
        XCTAssertEqual(fit.placements.filter {$0.day==0}.count,9)
        XCTAssertEqual(fit.placements.filter {$0.continuation}.count,1)
        let dense=AgendaPacking.fit(dayRows:[[20,20],[20,20,20],[20,20]],laneStarts:[0,0],bottom:85,gap:5)
        XCTAssertEqual(dense.completeDays,3)
    }
    func testCrossCalendarDuplicatesKeepAllSources() {
        let start=Date(timeIntervalSince1970:1000),end=Date(timeIntervalSince1970:4600)
        let first=AgendaItem(id:"a",title:"Meeting CP JD",start:start,end:end,allDay:false,calendarName:"Private",calendarID:"private")
        var copy=first;copy.id="b";copy.calendarID="family";copy.calendarName="Family";copy.title=" meeting  CP JD "
        let merged=AgendaDeduplication.merge([first,copy])
        XCTAssertEqual(merged.count,1)
        XCTAssertEqual(Set(merged[0].sources.map(\.id)),Set(["private","family"]))
        XCTAssertEqual(AgendaDeduplication.merge([copy,first]).map { $0.event.id },merged.map { $0.event.id })
        var later=copy;later.id="c";later.start=start.addingTimeInterval(86400);later.end=end.addingTimeInterval(86400)
        var longer=copy;longer.id="d";longer.end=end.addingTimeInterval(600)
        var elsewhere=copy;elsewhere.id="e";elsewhere.location="Other room"
        var allDay=copy;allDay.id="f";allDay.allDay=true
        XCTAssertEqual(AgendaDeduplication.merge([first,copy,later,longer,elsewhere,allDay]).count,5)
        var sameCalendar=first;sameCalendar.id="g"
        XCTAssertEqual(AgendaDeduplication.merge([first,sameCalendar,copy]).count,2)
    }
    func testFooterMigrationAndPerDisplayPersistence() throws {
        let old=try JSONDecoder().decode(DisplaySettings.self,from:Data(#"{"id":"old","name":"Old"}"#.utf8))
        XCTAssertEqual(old.footer.enabled,false)
        var first=old;first.footer.enabled=true;first.footer.lines=2
        var item=SensorFooterItem(entityID:"sensor.summary",label:"Weather")
        item.attribute="summary";item.format = .markdown;item.automaticUnit=false;item.unit="";item.decimals=1
        first.footer.items=[item]
        let saved=try JSONDecoder().decode([DisplaySettings].self,from:JSONEncoder().encode([first,old]))
        XCTAssertEqual(saved,[first,old])
    }
    func testSensorFormattingAndUnavailableAttributes() {
        var item=SensorFooterItem(entityID:"sensor.temperature",label:"Outside")
        let reading=SensorReading(id:item.entityID,name:"Outdoor sensor",state:"14.36",attributes:["unit_of_measurement":"°C","summary":"Bring **boots**"])
        XCTAssertEqual(SensorFormatting.value(for:item,reading:reading,locale:Locale(identifier:"en_US")).text,"14 °C")
        item.decimals=1
        XCTAssertEqual(SensorFormatting.value(for:item,reading:reading,locale:Locale(identifier:"de_DE")).text,"14,4 °C")
        item.attribute="summary";item.format = .markdown
        XCTAssertEqual(SensorFormatting.value(for:item,reading:reading).text,"Bring **boots**")
        item.attribute="missing"
        XCTAssertEqual(SensorFormatting.value(for:item,reading:reading).text,"Unavailable")
        XCTAssertEqual(SensorFormatting.value(for:item,reading:nil).format,.plain)
        var unavailable=reading;unavailable.state="unavailable"
        item.attribute="summary"
        XCTAssertEqual(SensorFormatting.value(for:item,reading:unavailable).text,"Unavailable")
        var binary=SensorFooterItem(entityID:"binary_sensor.washer",label:"Washer");binary.onText="Running";binary.offText="Idle"
        XCTAssertEqual(SensorFormatting.value(for:binary,reading:SensorReading(id:binary.entityID,name:"Washer",state:"on")).text,"Running")
    }
    func testFooterSamplesAreThrottledRoundedAndIndependent() {
        var sampler=FooterSampler(),settings=SensorFooterSettings();settings.enabled=true
        settings.items=[SensorFooterItem(entityID:"sensor.temp",label:"Outside")]
        let now=Date(timeIntervalSince1970:1000)
        func readings(_ state:String) -> [String:SensorReading] { ["sensor.temp":SensorReading(id:"sensor.temp",name:"Temperature",state:state)] }
        let first=sampler.snapshot(displayID:"one",settings:settings,readings:readings("14.1"),connected:true,now:now)
        let throttled=sampler.snapshot(displayID:"one",settings:settings,readings:readings("18"),connected:true,now:now.addingTimeInterval(60))
        XCTAssertEqual(first,throttled)
        let rounded=sampler.snapshot(displayID:"one",settings:settings,readings:readings("14.2"),connected:true,now:now.addingTimeInterval(1800))
        XCTAssertEqual(first,rounded)
        let other=sampler.snapshot(displayID:"two",settings:settings,readings:readings("18"),connected:true,now:now.addingTimeInterval(1801))
        XCTAssertEqual(other.values.first?.text,"18")
        let forced=sampler.snapshot(displayID:"one",settings:settings,readings:readings("18"),connected:true,now:now.addingTimeInterval(1802),force:true)
        XCTAssertEqual(forced.values.first?.text,"18")
    }
    func testFooterDisconnectRetainsValuesAndReconnectResamples() {
        var sampler=FooterSampler(),settings=SensorFooterSettings();settings.enabled=true
        settings.items=[SensorFooterItem(entityID:"sensor.temp",label:"Outside")]
        let now=Date(timeIntervalSince1970:1000),reading=SensorReading(id:"sensor.temp",name:"Temp",state:"14")
        let first=sampler.snapshot(displayID:"one",settings:settings,readings:[reading.id:reading],connected:true,now:now)
        let offline=sampler.snapshot(displayID:"one",settings:settings,readings:[:],connected:false,now:now.addingTimeInterval(10))
        XCTAssertEqual(offline.values,first.values);XCTAssertEqual(offline.stale,true)
        let reconnected=sampler.snapshot(displayID:"one",settings:settings,readings:[:],connected:true,now:now.addingTimeInterval(20))
        XCTAssertEqual(reconnected.stale,false);XCTAssertEqual(reconnected.values.first?.text,"Unavailable")
        sampler.reset()
        let reset=sampler.snapshot(displayID:"one",settings:settings,readings:[:],connected:false,now:now)
        XCTAssertEqual(reset.observedAt,nil);XCTAssertEqual(reset.values.first?.text,"Unavailable")
    }
    func testInlineMarkdownAndLiteralPlainText() {
        let source="Rain **70%** · *boots*\n[Forecast](https://example.com)"
        let spans=FooterMarkdown.spans(source,format:.markdown)
        XCTAssertEqual(spans.map(\.text).joined(),"Rain 70% · boots\nForecast")
        XCTAssertEqual(spans.filter(\.bold).map(\.text).joined(),"70%boots")
        XCTAssertEqual(FooterMarkdown.spans(source,format:.plain),[MarkdownSpan(text:source)])
        XCTAssertEqual(FooterMarkdown.spans("unfinished **bold",format:.markdown).map(\.text).joined(),"unfinished **bold")
        XCTAssertEqual(FooterMarkdown.spans("\\*literal\\*",format:.markdown).map(\.text).joined(),"*literal*")
    }
}

#if !canImport(XCTest)
@main struct CheckRules { static func main() throws { let t=RulesTests();t.testSevenDaysAcrossDaylightSavingBoundary();t.testIndependentListSortingAndUndatedLast();try t.testSettingsRoundTripPreservesPerDisplaySelections();try t.testExistingSettingsMigrationAndAbbreviations();t.testVariableDayPackingNeverDropsEntriesFromDisplayedDays();t.testOneBusyDayCanContinueAcrossColumnsWithoutOmission();t.testCrossCalendarDuplicatesKeepAllSources();try t.testFooterMigrationAndPerDisplayPersistence();t.testSensorFormattingAndUnavailableAttributes();t.testFooterSamplesAreThrottledRoundedAndIndependent();t.testFooterDisconnectRetainsValuesAndReconnectResamples();t.testInlineMarkdownAndLiteralPlainText();print("12 core behavior checks passed") } }
#endif
