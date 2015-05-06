import base14, tables, strutils, collect, strtabs, unicode, math

import Font, CMAPTable, HEADTable, HMTXTable, FontData

const
    defaultFont = "Times00"
    
type
    FontStyle* = enum
        FS_REGULAR, FS_ITALIC, FS_BOLD
    
    FontStyles* = set[FontStyle]

    FontType* = enum
        FT_BASE14, FT_TRUETYPE
        
    BBox = object 
        x1,y1,x2,y2 : int
    
    Font* = ref object of RootObj
        ID*: int
        objID*: int
        subType*: FontType
        searchName*: string
        
    TTFont* = ref object of Font
        font*: FontDef
        cmap: CMAP
        hmtx: HMTXTable
        scaleFactor: float64
        CH2GID*: CH2GIDMAP
        newGID: int

    Base14* = ref object of Font
        baseFont* : string
        get_width : proc(cp: int): int
        is_font_specific : bool
        ascent, descent, x_height, cap_height : int
        bbox : BBox

    TextWidth* = object
        numchars*, width*, numspace*, numwords*: int
    
    FontManager* = object
        FontList*: seq[Font]
        BaseFont: seq[Base14]
        TTFontList: StringTableRef
        TTCList: StringTableRef

proc GetCharWidth(f: TTFont, gid: int): int =
    result = math.round(float(f.hmtx.AdvanceWidth(gid)) * f.scaleFactor)
    
proc GenerateWidths*(f: TTFont): string =
    f.CH2GID.sort(proc(x,y: tuple[key: int, val: TONGID]):int = cmp(x.val.newGID, y.val.newGID) )
    var widths = "[ 1["
    var x = 0
    
    for gid in values(f.CH2GID):
        widths.add($f.GetCharWidth(gid.oldGID))
        if x < f.CH2GID.len-1: widths.add(' ')
        inc(x)
        
    widths.add("]]")
    result = widths
    
proc GenerateRanges*(f: TTFont): string =
    var range: seq[string] = @[]
    var mapping = ""
    
    for code, gid in pairs(f.CH2GID):
        if range.len >= 100:
            mapping.add("\x0A" & $range.len & " beginbfchar\x0A" & join(range, "\x0A") & "\x0Aendbfchar")
            range = @[]
        range.add("<" & toHex(gid.newGID, 4) & "><" & toHex(code, 4) & ">")

    if range.len > 0:
        mapping.add("\x0A" & $range.len & " beginbfchar\x0A" & join(range, "\x0A") & "\x0Aendbfchar")
    
    result = mapping

proc GetDescriptor*(f: TTFont): FontDescriptor =
   f.CH2GID.sort(proc(x,y: tuple[key: int, val: TONGID]):int = cmp(x.key, y.key) )
   result = f.font.makeDescriptor(f.CH2GID)
   
proc GetSubsetBuffer*(f: TTFont, subsetTag: string): string =
   let fd   = f.font.Subset(f.CH2GID, subsetTag)
   result = fd.GetInternalBuffer()

method EscapeString*(f: Font, text: string): string =
    discard

method EscapeString*(f: Base14, text: string): string =
    result = text

method EscapeString*(f: TTFont, text: string): string =
    for c in runes(text):
        let charCode = int(c)
        if not f.CH2GID.hasKey(charCode):
            let oldGID = f.cmap.GlyphIndex(charCode)
            if oldGID != 0:
                f.CH2GID[charCode] = (oldGID, f.newGID)
                inc(f.newGID)
    
    result = ""
    for c in runes(text):
        let charCode = int(c)
        if f.CH2GID.hasKey(charCode):
            let gid = f.CH2GID[charCode].newGID
            result.add(toHex(gid, 4))
        else:
            result.add("0000")

method GetTextWidth*(f: Font, text: string): TextWidth =
    discard

method GetTextWidth*(f: TTFont, text: string): TextWidth =
    result.width = 0
    result.numchars = 0
    result.numwords = 0
    result.numspace = 0
    
    for b in runes(text):
        inc(result.numchars)
        result.width += f.GetCharWidth(int(b))
        if isWhiteSpace(b):
            inc(result.numspace)
            inc(result.numwords)
    
    let lastChar = runeLen(text) - 1
    if not isWhiteSpace(runeAt(text, lastChar)):
        inc(result.numwords)

method GetTextWidth*(f: Base14, text: string): TextWidth =
    result.numchars = 0
    result.width = 0
    result.numspace = 0
    result.numwords = 0
    var b:char
    
    for i in 0..text.len-1:
        b = text[i]
        inc(result.numchars)
        result.width += f.get_width(ord(b))
        if b in Whitespace:
            inc(result.numspace)
            inc(result.numwords)
 
    if b notin Whitespace:
        inc(result.numwords)
    
proc reverse(s: string): string =
    result = newString(s.len)
    for i in 1..s.len:
        result[i-1] = s[s.len-i]

proc toBase26*(number: int): string =
    var n = number
    if n < 0: n = -n
    var converted = ""        
    
    #Repeatedly divide the number by 26 and convert the
    #remainder into the appropriate letter.
    while n > 0:
        let remainder = n mod 26
        converted.add(chr(remainder + ord('A')))
        n = int((n - remainder) / 26)
    result = reverse(converted)

proc fromBase26*(number: string): int =
    result = 0
    if number.len > 0:
        for i in 0..number.len - 1:
            result += (ord(number[i]) - ord('A'))
            #echo " ", $result
            if i < number.len-1: result *= 26

proc searchFrom[T](list: seq[T], name: string): Font =
    result = nil
    for i in items(list):
        if i.searchName == name: 
            result = i
            break
            
proc init*(ff: var FontManager, fontDir: string = "fonts") =
    ff.FontList = @[]
    ff.TTFontList = collectTTF(fontDir)
    ff.TTCList = collectTTC(fontDir)

    #echo "TTList len ", ff.TTFontList.len
    #echo "TTCList len ", ff.TTCList.len
    
    newSeq(ff.BaseFont, 14)
    
    for i in 0..high(BUILTIN_FONTS):
        new(ff.BaseFont[i])
        ff.BaseFont[i].baseFont   = BUILTIN_FONTS[i][0]
        ff.BaseFont[i].searchName = BUILTIN_FONTS[i][1]
        ff.BaseFont[i].get_width  = BUILTIN_FONTS[i][2]
        ff.BaseFont[i].subType    = FT_BASE14
    
    #put default font
    var res = searchFrom(ff.BaseFont, defaultFont)
    res.ID = ff.FontList.len + 1
    ff.FontList.add(res)

proc makeTTFont(font: FontDef, searchName: string): TTFont = 
    var cmap = CMAPTable(font.GetTable(TAG.cmap))
    var head = HEADTable(font.GetTable(TAG.head))
    var hmtx = HMTXTable(font.GetTable(TAG.hmtx))
    if cmap == nil or head == nil or hmtx == nil: return nil
    var encodingcmap = cmap.GetEncodingCMAP()
    
    if encodingcmap == nil:
        echo "no unicode cmap found"
        return nil
    
    var res: TTFont
    new(res)
    
    res.subType    = FT_TRUETYPE
    res.searchName = searchName
    res.font       = font
    res.cmap       = encodingcmap
    res.hmtx       = hmtx
    res.scaleFactor= 1000 / head.UnitsPerEm()
    res.CH2GID     = initOrderedTable[int, TONGID]()
    res.newGID     = 1
    result = res
    
proc searchFromTTList(ff: FontManager, name:string): Font =
    if not ff.TTFontList.hasKey(name): return nil    
    let fileName = ff.TTFontList[name]
    let font = LoadTTF(fileName)
    if font != nil: return makeTTFont(font, name)
    result = nil

proc searchFromTTCList(ff: FontManager, name:string): Font =
    if not ff.TTCList.hasKey(name): return nil
    let fName = ff.TTCList[name]
    let fileName = substr(fName, 0, fName.len - 2)
    let fontIndex = ord(fName[fName.len-1]) - ord('0')
    let font = LoadTTC(fileName, fontIndex)
    if font != nil: return makeTTFont(font, name)
    result = nil
    
proc makeSubsetTag*(number: int): string =
    let val = toBase26(number)
    let blank = 6 - val.len
    result = repeatChar(blank, 'A')
    result.add(val)
    result.add('+')

proc makeFont*(ff: var FontManager, family:string = "Times", style:FontStyles = {FS_REGULAR}): Font =
    var searchStyle = "00"
    if FS_BOLD in style: searchStyle[0] = '1'
    if FS_ITALIC in style: searchStyle[1] = '1'
    
    var searchName = family 
    searchName.add(searchStyle)
    
    var res = searchFrom(ff.FontList, searchName)
    if res != nil: return res
    
    res = searchFrom(ff.BaseFont, searchName)
    if res != nil:
        #echo "Base 14 Font ", searchName
        res.ID = ff.FontList.len + 1
        ff.FontList.add(res)
        return res
    
    res = searchFromTTList(ff, searchName)
    if res != nil:
        #echo "TT Font ", searchName
        res.ID = ff.FontList.len + 1
        ff.FontList.add(res)
        return res

    res = searchFromTTCList(ff, searchName)
    if res != nil: 
        #echo "TTC Font ", searchName
        res.ID = ff.FontList.len + 1
        ff.FontList.add(res)
        return res
    
    #echo "Fall Back ", searchName
    result = searchFrom(ff.FontList, defaultFont)

when isMainModule:
    var ff: FontManager
    ff.init()
    
    for key, val in pairs(ff.TTFontList): 
        echo key, ": ", val
      
    var font = ff.makeFont("GoodDog", {FS_REGULAR})
    if font == nil: 
        echo "NULL"
    else:
        echo font.searchName
    
    var times = ff.makeFont("GoodDogx", {FS_REGULAR})
    echo times.searchName