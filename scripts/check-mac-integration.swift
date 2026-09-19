import AppKit
import Foundation
import MacLinkCore

@main
struct IntegrationChecks {
    @MainActor static func main() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1])
        try renderChecks(output:output)
        if CommandLine.arguments.count>2 {
            let url=try HomeAssistant.validatedURL(CommandLine.arguments[2])
            precondition(url.host == "127.0.0.1", "Integration checks require a loopback fixture")
            try await connectionChecks(url:url)
        }
    }

    @MainActor static func renderChecks(output:URL) throws {
        let now=ISO8601DateFormatter().date(from:"2026-09-19T10:00:00Z")!
        var settings=DisplaySettings(id:"demo",name:"Family · sample data")
        settings.calendarIDs=["family"]
        settings.footer.enabled=true;settings.footer.lines=2
        settings.footer.items=(0..<4).map { SensorFooterItem(entityID:"sensor.\($0)",label:"") }
        let events=(0..<9).map { index in AgendaItem(id:"\(index)",title:["Family breakfast","Library books back","Swimming lesson","School meeting","Dinner with friends","Bike ride","Pick up parcel","Prepare for school","Visit grandparents"][index],start:now.addingTimeInterval(Double(index)*86400),end:now.addingTimeInterval(Double(index)*86400+3600),allDay:false,calendarName:"Family",calendarID:"family") }
        let footer=FooterSnapshot(values:[
            FooterValue(label:"Outside",text:"14 °C"),
            FooterValue(label:"Rain",text:"**70%**\nBring **boots**",format:.markdown),
            FooterValue(label:"Washer",text:"Running"),
            FooterValue(label:"",text:"Paper bin **tomorrow** · an intentionally long reminder that must fit its allocated space",format:.markdown)
        ],observedAt:now,stale:false)
        let first=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now,footer:footer)
        let second=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now,footer:footer)
        precondition(first.pixelHash==second.pixelHash)
        var laterSample=footer;laterSample.observedAt=now.addingTimeInterval(3600)
        let laterFrame=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now,footer:laterSample)
        precondition(first.pixelHash==laterFrame.pixelHash)
        try first.png.write(to:output)
        var weatherSettings=settings;weatherSettings.footer.items=Array(settings.footer.items.prefix(2))
        let weather=FooterSnapshot(values:[
            FooterValue(label:"",text:"**Heute 06–22:** 18,5–21,1 °C · Wind 26/Böen 53 km/h | **Morgen 06–22:** 14,1–21,4 °C · Regen 100%/3,7 mm · Wind 25/Böen 52 km/h",format:.markdown),
            FooterValue(label:"",text:"**PV heute:** 14,6 kWh | **PV morgen:** 21,9 kWh",format:.markdown)
        ],observedAt:now,stale:false)
        let weatherLayout=try SensorFooterRenderer.layout(weather,settings:weatherSettings.footer,width:800)
        precondition(weatherLayout.rows.count==2)
        precondition(weatherLayout.rows.map(\.lines)==[2,1])
        precondition(weatherLayout.rows.allSatisfy {$0.widths==[768]})
        let weatherFrame=try DashboardRenderer.render(settings:weatherSettings,events:events,groups:[],now:now,footer:weather)
        try weatherFrame.png.write(to:output.deletingLastPathComponent().appendingPathComponent("footer-weather-pv.png"))
        var stale=footer;stale.stale=true
        let staleFrame=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now,footer:stale)
        precondition(first.pixelHash != staleFrame.pixelHash)
        try staleFrame.png.write(to:output.deletingLastPathComponent().appendingPathComponent("footer-stale.png"))
        settings.footer.enabled=false
        let disabled=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now,footer:footer)
        settings.footer=SensorFooterSettings()
        let noFooter=try DashboardRenderer.render(settings:settings,events:events,groups:[],now:now)
        precondition(disabled.pixelHash==noFooter.pixelHash)
        try noFooter.png.write(to:output.deletingLastPathComponent().appendingPathComponent("footer-disabled.png"))
        let normal=try SensorFooterRenderer.attributed(FooterValue(label:"",text:"Regular **bold**",format:.markdown))
        precondition(normal.string=="Regular bold")
        precondition((normal.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.fontName == "TRMNL16-Regular")
        precondition((normal.attribute(.font,at:8,effectiveRange:nil) as? NSFont)?.fontName == "TRMNL16-Bold")
        let bitmap=NSBitmapImageRep(data:first.png)!
        precondition(bitmap.pixelsWide==800 && bitmap.pixelsHigh==480)
        precondition(bitmap.bitsPerSample==8 && bitmap.samplesPerPixel==4 && !bitmap.isPlanar)
        let bytes=bitmap.bitmapData!
        for y in 0..<480 { for x in 0..<800 {
            let offset=y*bitmap.bytesPerRow+x*4
            precondition((bytes[offset]==0 || bytes[offset]==255) && bytes[offset]==bytes[offset+1] && bytes[offset+1]==bytes[offset+2] && bytes[offset+3]==255)
        } }
        print("Renderer checks passed: Markdown fonts, bounded footer, stale state, disabled equivalence, deterministic monochrome pixels")
    }

    @MainActor static func eventually(_ label:String,_ condition:() -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw DataError("Timed out: \(label)")
    }

    @MainActor static func connectionChecks(url:URL) async throws {
        for invalid in ["file:///etc/passwd","https://user:secret@example.com","http://localhost?token=secret"] {
            precondition((try? HomeAssistant.validatedURL(invalid)) == nil)
        }
        let home=HomeAssistant()
        home.start(url:url,token:"fixture-token")
        defer { home.stop(clear:true) }
        try await eventually("initial sensor snapshot") { home.ready && home.readings["sensor.temperature"]?.state == "14.1" }
        precondition(home.readings.count==3)
        precondition(home.readings["sensor.summary"]?.attributes["content"] == "Rain **70%**")
        try await eventually("state and attribute updates") { home.readings["sensor.temperature"]?.state == "15.2" }
        precondition(home.readings["sensor.summary"]?.attributes["content"] == "Bring **boots**")
        try await eventually("removed entity") { home.readings["sensor.summary"] == nil }
        try await eventually("connection loss") { !home.ready }
        precondition(home.readings["sensor.temperature"]?.state == "15.2")
        home.checkConnection()
        try await eventually("fresh snapshot after reconnect") { home.ready && home.readings["sensor.temperature"]?.state == "16.0" }
        precondition(home.readings["binary_sensor.washer"] == nil)
        try await eventually("unavailable sensor") { home.readings["sensor.temperature"]?.state == "unavailable" }
        home.stop(clear:true)
        home.start(url:url,token:"rejected-fixture-token")
        try await eventually("rejected credential") { home.status == "Access denied" }
        precondition(!home.ready && !home.connecting && home.problem != nil)
        print("HAKit integration checks passed: authentication, discovery, state/attribute updates, deletion, disconnect retention, reconnect replacement, unavailable state, rejected token")
    }
}
