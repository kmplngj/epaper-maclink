import AppKit
import CoreText
import MacLinkCore

@MainActor
enum SensorFooterRenderer {
    struct Row {
        var contents:[NSAttributedString]
        var widths:[Int]
        var lines:Int
    }
    struct Layout {
        var rows:[Row]
        var height:Int { rows.isEmpty ? 0:14+rows.reduce(0) { $0+$1.lines*20 }+(rows.count-1)*6 }
    }
    static func attributed(_ value:FooterValue) throws -> NSAttributedString {
        let result=NSMutableAttributedString(string:"")
        func append(_ text:String,bold:Bool) throws {
            let font=try EinkFonts.font(16,bold:bold),emoji=try EinkFonts.emoji(16)
            for character in text {
                let scalars=character.unicodeScalars
                let isEmoji=scalars.contains {$0.properties.isEmojiPresentation} || scalars.contains {$0.value==0xFE0F}
                let text=String(character).replacingOccurrences(of:"\u{FE0F}",with:"")
                result.append(NSAttributedString(string:text,attributes:[.font:isEmoji ? emoji:font,.foregroundColor:NSColor.black,.kern:0]))
            }
        }
        if !value.label.isEmpty { try append(value.label+" ",bold:false) }
        for span in FooterMarkdown.spans(value.text,format:value.format) {
            try append(span.text,bold:value.format == .plain || span.bold)
        }
        return result
    }

    static func layout(_ snapshot:FooterSnapshot,settings:SensorFooterSettings,width:Int) throws -> Layout {
        guard settings.enabled,!settings.items.isEmpty else { return Layout(rows:[]) }
        let available=width-32,gap=24
        var contents=try settings.visibleItems.enumerated().map { index,item in
            try attributed(index<snapshot.values.count ? snapshot.values[index]:FooterValue(label:item.label,text:"Unavailable"))
        }
        if snapshot.stale {
            let prefix=NSMutableAttributedString(string:snapshot.observedAt == nil ? "Waiting · ":"Offline · ",attributes:[.font:try EinkFonts.font(12,bold:true),.foregroundColor:NSColor.black])
            prefix.append(contents[0]);contents[0]=prefix
        }
        let natural=contents.map(intrinsicWidth)
        func required(_ indices:Range<Int>)->Int { indices.reduce(0) {$0+natural[$1]}+max(0,indices.count-1)*gap }
        var groups=[0..<contents.count]
        if contents.count>1,required(groups[0])>available {
            let split=(1..<contents.count).min { a,b in
                max(required(0..<a),required(a..<contents.count)) < max(required(0..<b),required(b..<contents.count))
            }!
            groups=[0..<split,split..<contents.count]
        }
        let rows=groups.map { indices -> Row in
            var texts=indices.map { contents[$0] }
            var widths=Array(repeating:0,count:indices.count)
            var active=Array(widths.indices),remaining=available-gap*(indices.count-1)
            while !active.isEmpty {
                let share=remaining/active.count
                let short=active.filter { natural[indices.lowerBound+$0]<=share }
                if short.isEmpty {
                    for index in active { widths[index]=share }
                    widths[active.last!]+=remaining-share*active.count
                    break
                }
                for index in short { widths[index]=natural[indices.lowerBound+index];remaining-=widths[index] }
                active.removeAll { short.contains($0) }
                if active.isEmpty {
                    for index in widths.indices { widths[index]+=remaining/widths.count }
                    widths[widths.count-1]+=remaining%widths.count
                }
            }
            for index in texts.indices where settings.lineCount>1 && natural[indices.lowerBound+index]>widths[index] {
                let wrapped=NSMutableAttributedString(attributedString:texts[index])
                wrapped.mutableString.replaceOccurrences(of:" | ",with:"\n",range:NSRange(location:0,length:wrapped.length))
                texts[index]=wrapped
            }
            let lines=zip(texts,widths).map { lineCount($0.0,width:max(1,$0.1),limit:settings.lineCount) }.max() ?? 1
            return Row(contents:texts,widths:widths,lines:lines)
        }
        return Layout(rows:rows)
    }

    static func draw(_ layout:Layout,width:Int,top:Int,context:CGContext) {
        let margin=16,gap=24
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x:margin,y:top,width:width-margin*2,height:1))
        var y=top+8
        for row in layout.rows {
            var x=margin
            for index in row.contents.indices {
                if index>0 { context.fill(CGRect(x:x-gap/2,y:y+3,width:1,height:14)) }
                drawLines(row.contents[index],x:x,y:y,width:row.widths[index],lines:row.lines,context:context)
                x+=row.widths[index]+gap
            }
            y+=row.lines*20+6
        }
    }

    private static func lineCount(_ text:NSAttributedString,width:Int,limit:Int)->Int {
        let typesetter=CTTypesetterCreateWithAttributedString(text),string=text.string as NSString
        var offset=0,count=0
        while offset<text.length,count<limit {
            var length=max(1,CTTypesetterSuggestLineBreak(typesetter,offset,Double(width)))
            let newline=string.range(of:"\n",range:NSRange(location:offset,length:text.length-offset))
            if newline.location != NSNotFound { length=min(length,newline.location-offset+1) }
            offset+=length;count+=1
        }
        return max(1,count)
    }

    private static func intrinsicWidth(_ text:NSAttributedString)->Int {
        let string=text.string as NSString
        var offset=0,width=1
        while offset<text.length {
            let newline=string.range(of:"\n",range:NSRange(location:offset,length:text.length-offset))
            let end=newline.location == NSNotFound ? text.length:newline.location
            let line=CTLineCreateWithAttributedString(text.attributedSubstring(from:NSRange(location:offset,length:end-offset)))
            width=max(width,Int(ceil(CTLineGetTypographicBounds(line,nil,nil,nil))))
            offset=end+1
        }
        return width
    }

    private static func drawLines(_ text:NSAttributedString,x:Int,y:Int,width:Int,lines:Int,context:CGContext) {
        let typesetter=CTTypesetterCreateWithAttributedString(text),string=text.string as NSString
        var offset=0
        context.saveGState();defer { context.restoreGState() }
        context.clip(to:CGRect(x:x,y:y,width:width,height:lines*20))
        for row in 0..<lines where offset<text.length {
            let remaining=NSRange(location:offset,length:text.length-offset)
            if row==lines-1 {
                let tail=NSMutableAttributedString(attributedString:text.attributedSubstring(from:remaining))
                tail.mutableString.replaceOccurrences(of:"\n",with:" ",range:NSRange(location:0,length:tail.length))
                let line=CTLineCreateWithAttributedString(tail)
                let token=NSAttributedString(string:"…",attributes:text.attributes(at:offset,effectiveRange:nil))
                let fitted=CTLineCreateTruncatedLine(line,Double(width),.end,CTLineCreateWithAttributedString(token)) ?? line
                drawLine(fitted,x:x,y:y+row*20+16,context:context)
                break
            }
            var length=max(1,CTTypesetterSuggestLineBreak(typesetter,offset,Double(width)))
            let newline=string.range(of:"\n",range:remaining)
            if newline.location != NSNotFound { length=min(length,newline.location-offset+1) }
            let line=CTTypesetterCreateLine(typesetter,CFRange(location:offset,length:length))
            drawLine(line,x:x,y:y+row*20+16,context:context)
            offset+=length
        }
    }

    private static func drawLine(_ line:CTLine,x:Int,y:Int,context:CGContext) {
        context.saveGState();defer { context.restoreGState() }
        context.translateBy(x:CGFloat(x),y:CGFloat(y));context.scaleBy(x:1,y:-1)
        context.textMatrix = .identity;context.textPosition = .zero;CTLineDraw(line,context)
    }
}
