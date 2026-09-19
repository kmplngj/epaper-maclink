import AppKit
import CoreText
import CryptoKit
import MacLinkCore

struct RenderedFrame {
    let png:Data
    let image:NSImage
    let pixelHash:String
}

@MainActor
enum EinkFonts {
    private static var registered=false
    static func font(_ size:Int,bold:Bool=false) throws -> NSFont {
        if !registered {
            for name in ["TRMNL12-Regular","TRMNL12-Bold","TRMNL16-Regular","TRMNL16-Bold","TRMNL21-Bold","NotoEmoji"] {
                guard let url=Bundle.module.url(forResource:name,withExtension:"ttf",subdirectory:"Fonts") else { throw DataError("The e-paper font bundle is missing. Reinstall MacLink.") }
                CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
            }
            registered=true
        }
        guard let result=NSFont(name:"TRMNL\(size)-\(bold ? "Bold":"Regular")",size:CGFloat(size)) else { throw DataError("Couldn't load the e-paper font.") }
        return result
    }
    static func emoji(_ size:Int) throws -> NSFont {
        _ = try font(12)
        guard let font=NSFont(name:"NotoEmoji-Regular",size:CGFloat(size)) else { throw DataError("Couldn't load the monochrome symbol font.") }
        let descriptor=font.fontDescriptor.addingAttributes([NSFontDescriptor.AttributeName(rawValue:kCTFontVariationAttribute as String):[2003265652:700]])
        return NSFont(descriptor:descriptor,size:CGFloat(size)) ?? font
    }
}

@MainActor
enum DashboardRenderer {
    private struct EventRow {
        let lines:[String]
        let stamp:String
        let tags:[String]
        let empty:Bool
    }
    static func render(settings:DisplaySettings,events:[AgendaItem],groups:[TaskGroup],now:Date,compact:Bool=false,footer:FooterSnapshot=FooterSnapshot()) throws -> RenderedFrame {
        let width=settings.width,height=settings.height
        guard width>=400,height>=240,width%8==0 else { throw DataError("This dashboard needs a display at least 400 × 240 pixels wide.") }
        let body=try EinkFonts.font(compact ? 12:16,bold:true),small=try EinkFonts.font(12),label=try EinkFonts.font(12,bold:true),heading=try EinkFonts.font(21,bold:true)
        let emoji12=try EinkFonts.emoji(12),emoji16=try EinkFonts.emoji(16),emoji21=try EinkFonts.emoji(21)
        let rowHeight=compact ? 15:20
        let footerLayout=try SensorFooterRenderer.layout(footer,settings:settings.footer,width:width)
        let top=48,bottom=height-14-footerLayout.height,margin=16,gap=24
        let laneWidth=(width-margin*2-gap)/2
        let laneX=[margin,margin+laneWidth+gap]
        let calendar=Calendar.current,start=calendar.startOfDay(for:now)
        let time=DateFormatter();time.dateFormat="HH:mm"
        let day=DateFormatter();day.dateFormat="EEE d"
        let dateTitle=DateFormatter();dateTitle.dateFormat="EEEE, d MMMM"
        func styled(_ text:String,_ font:NSFont)->NSAttributedString {
            let result=NSMutableAttributedString(string:"")
            for character in text {
                let scalars=character.unicodeScalars
                let emoji=scalars.contains {$0.properties.isEmojiPresentation} || (scalars.contains {$0.value==0xFE0F} && scalars.contains {$0.properties.isEmoji})
                let face=emoji ? (font.pointSize>18 ? emoji21:(font.pointSize>12 ? emoji16:emoji12)):font
                // Explicit monochrome font plus text presentation avoids Apple Color Emoji.
                let value=emoji ? String(character).replacingOccurrences(of:"\u{FE0F}",with:""):String(character)
                result.append(NSAttributedString(string:value,attributes:[.font:face,.foregroundColor:NSColor.black,.kern:0]))
            }
            return result
        }
        func textWidth(_ text:String,_ font:NSFont)->Int {
            let line=CTLineCreateWithAttributedString(styled(text,font))
            return Int(ceil(CTLineGetTypographicBounds(line,nil,nil,nil)))
        }
        func wrapped(_ text:String,_ font:NSFont,_ maxWidth:Int)->[String] {
            let attributed=styled(text.replacingOccurrences(of:"\n",with:" "),font)
            let string=attributed.string as NSString
            let typesetter=CTTypesetterCreateWithAttributedString(attributed)
            var result:[String]=[],offset=0
            while offset<string.length {
                let length=max(1,CTTypesetterSuggestLineBreak(typesetter,offset,Double(maxWidth)))
                result.append(string.substring(with:NSRange(location:offset,length:length)).trimmingCharacters(in:.whitespaces))
                offset+=length
            }
            return result.isEmpty ? [""]:result
        }
        let entries=AgendaDeduplication.merge(events)
        func sourceTags(_ entry:AgendaEntry)->[String] {
            if entry.sources.count>1 { return [String(entry.sources.count)] }
            return entry.sources.map { settings.abbreviation(for:$0.id,name:$0.name) }.filter { !$0.isEmpty }
        }
        let tags=entries.flatMap(sourceTags)
        let tagWidth=tags.map { textWidth($0,small) }.max() ?? 0
        let timeWidth=max(textWidth("all day",small),textWidth("ongoing",small),textWidth("23:59",small))+5
        let tagOffset=48+timeWidth
        let titleOffset=tagOffset+(tagWidth>0 ? tagWidth+6:0)
        let titleWidth=laneWidth-titleOffset
        var dates:[Date]=[],dayRows:[[EventRow]]=[]
        for index in 0..<settings.effectiveCalendarDays {
            let date=calendar.date(byAdding:.day,value:index,to:start)!,next=calendar.date(byAdding:.day,value:1,to:date)!
            dates.append(date)
            let matches=entries.filter { $0.event.start<next && $0.event.end>date }
            if matches.isEmpty {
                dayRows.append([EventRow(lines:[settings.calendarIDs.isEmpty ? "No calendars selected":"No events"],stamp:"",tags:[],empty:true)])
            } else {
                dayRows.append(matches.map { entry in
                    let event=entry.event
                    let stamp=event.allDay ? "all day":(event.start<date ? "ongoing":time.string(from:event.start))
                    return EventRow(lines:wrapped(event.title,body,titleWidth),stamp:stamp,tags:sourceTags(entry),empty:false)
                })
            }
        }
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else { throw DataError("Couldn't create the display image.") }
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=context
        let cg=context.cgContext
        cg.setFillColor(NSColor.white.cgColor);cg.fill(CGRect(x:0,y:0,width:width,height:height))
        // Native pixel sizes and integer baselines; no scaled canvas or smoothing.
        cg.translateBy(x:0,y:CGFloat(height));cg.scaleBy(x:1,y:-1)
        cg.setAllowsAntialiasing(false);cg.setShouldAntialias(false)
        cg.setAllowsFontSmoothing(false);cg.setShouldSmoothFonts(false)
        cg.setAllowsFontSubpixelPositioning(false);cg.setShouldSubpixelPositionFonts(false)
        cg.setAllowsFontSubpixelQuantization(false);cg.setShouldSubpixelQuantizeFonts(false)
        func text(_ value:String,x:Int,y:Int,font:NSFont,maxWidth:Int?=nil,baseline:Int?=nil) {
            let original=CTLineCreateWithAttributedString(styled(value,font))
            var line=original
            if let maxWidth,CTLineGetTypographicBounds(original,nil,nil,nil)>Double(maxWidth) {
                let ellipsis=CTLineCreateWithAttributedString(styled("…",font))
                line=CTLineCreateTruncatedLine(original,Double(maxWidth),.end,ellipsis) ?? original
            }
            cg.saveGState();cg.translateBy(x:CGFloat(x),y:CGFloat(y+(baseline ?? Int(font.ascender.rounded()))));cg.scaleBy(x:1,y:-1)
            cg.textMatrix = .identity;cg.textPosition = .zero;CTLineDraw(line,cg);cg.restoreGState()
        }
        func rule(x:Int,y:Int,w:Int) { cg.setFillColor(NSColor.black.cgColor);cg.fill(CGRect(x:x,y:y,width:w,height:1)) }
        text(dateTitle.string(from:now),x:margin,y:8,font:heading,maxWidth:width-210)
        text(settings.name,x:width-margin-min(180,textWidth(settings.name,label)),y:16,font:label,maxWidth:180)
        rule(x:margin,y:38,w:width-margin*2)
        var rightStart=top
        if !settings.reminderLists.isEmpty {
            let x=laneX[1],limit=top+(bottom-top)*2/5
            var y=top,remaining=groups.reduce(0) { $0+$1.items.count },stopped=false
            for group in groups {
                if y+34>limit { break }
                text(group.name.uppercased(),x:x,y:y,font:label,maxWidth:laneWidth);y+=18
                if group.items.isEmpty { text("All done",x:x,y:y,font:body,maxWidth:laneWidth);y+=rowHeight }
                for item in group.items {
                    let lines=wrapped(item.title,body,laneWidth-18)
                    let required=lines.count*rowHeight+(item.due==nil ? 0:15)+4
                    if y+required>limit-15 { stopped=true;break }
                    cg.setStrokeColor(NSColor.black.cgColor);cg.setLineWidth(1);cg.stroke(CGRect(x:x+1,y:y+4,width:9,height:9))
                    for (i,line) in lines.enumerated() { text(line,x:x+18,y:y+i*rowHeight,font:body) }
                    y+=lines.count*rowHeight
                    if let due=item.due {
                        let df=DateFormatter();df.dateFormat="d MMM"
                        let dateLabel=calendar.isDate(due,inSameDayAs:now) ? (item.dateOnly ? "Today":"Today · \(time.string(from:due))"):df.string(from:due)
                        text((due<start ? "Overdue · ":"")+dateLabel,x:x+18,y:y,font:small,maxWidth:laneWidth-18);y+=15
                    }
                    y+=4;remaining-=1
                }
                y+=6
                if stopped { break }
            }
            if remaining>0 { text("+\(remaining) reminders",x:x,y:min(y,limit-15),font:small);y=min(y,limit-15)+15 }
            rule(x:x,y:y+3,w:laneWidth);rightStart=y+14
        }
        let fit=AgendaPacking.fit(dayRows:dayRows.map { rows in rows.map { max(max(1,$0.lines.count)*rowHeight,$0.tags.count*15+4) } },laneStarts:[top,rightStart],bottom:bottom)
        if fit.completeDays==0 {
            if !compact { return try render(settings:settings,events:events,groups:groups,now:now,compact:true,footer:footer) }
            throw DataError("Today's calendar entries exceed the display's capacity. Select fewer calendars or reduce the sensor footer; no partial day was published.")
        }
        for placement in fit.placements {
            let row=dayRows[placement.day][placement.row],x=laneX[placement.lane],y=placement.y
            if placement.row==0 || placement.continuation {
                text(day.string(from:dates[placement.day]),x:x,y:y,font:label,maxWidth:44,baseline:Int(body.ascender.rounded()))
                if placement.continuation { text("cont.",x:x,y:y+13,font:small,maxWidth:44) }
            }
            if row.empty { text(row.lines[0],x:x+48,y:y,font:small,maxWidth:laneWidth-48,baseline:Int(body.ascender.rounded())) }
            else {
                text(row.stamp,x:x+48,y:y,font:small,maxWidth:timeWidth-4,baseline:Int(body.ascender.rounded()))
                for (i,tag) in row.tags.enumerated() { text(tag,x:x+tagOffset,y:y+i*15,font:small,maxWidth:tagWidth,baseline:Int(body.ascender.rounded())) }
                for (i,line) in row.lines.enumerated() { text(line,x:x+titleOffset,y:y+i*rowHeight,font:body) }
            }
        }
        if footerLayout.height>0 {
            SensorFooterRenderer.draw(footerLayout,width:width,top:bottom+6,context:cg)
        }
        guard let bytes=bitmap.bitmapData else { throw DataError("Couldn't read rendered pixels.") }
        var packed=Data(repeating:0,count:width*height/8)
        for y in 0..<height { for x in 0..<width {
            let i=y*bitmap.bytesPerRow+x*4
            let white=(Int(bytes[i])*299+Int(bytes[i+1])*587+Int(bytes[i+2])*114)>=128000
            let v:UInt8=white ? 255:0
            bytes[i]=v;bytes[i+1]=v;bytes[i+2]=v;bytes[i+3]=255
            if white { packed[y*(width/8)+x/8] |= UInt8(1<<(7-x%8)) }
        } }
        let hash=SHA256.hash(data:Data("mono1:white=1:msb:\(width):\(height):".utf8)+packed).map { String(format:"%02x",$0) }.joined()
        guard let png=bitmap.representation(using:.png,properties:[:]) else { throw DataError("Couldn't encode the display image.") }
        let image=NSImage(size:NSSize(width:width,height:height));image.addRepresentation(bitmap)
        return RenderedFrame(png:png,image:image,pixelHash:hash)
    }
}
