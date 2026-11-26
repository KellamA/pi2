// The window's text cleaner and picture maker (TranscriptKit's `PresentationText` and `PresentedPicture`), each with the
// cases #1001's security reads tried: every text someone else chose is drawn plain, and a picture is made only as the
// kind its bytes are.

import AppKit
import TranscriptKit

@MainActor
func presentationTexts() async {
    await group("a name or caption is drawn plain: no line breaks, format characters, stacked marks or quotation marks") {
        let cases: [(String, String, Bool, String)] = [
            ("line breaks", "A\nVersion 3 of 3\r\nB\u{2028}C\u{2029}D\u{85}E\tF", false, "A Version 3 of 3 B C D E F"),
            ("bidirectional controls", "\u{202E}gnp.exe\u{202C} x \u{2066}y\u{2069}\u{200F}\u{061C}", false, "gnp.exe x y"),
            ("zero-width and format characters", "a\u{200B}b\u{200D}c\u{2060}d\u{FEFF}e\u{00AD}f\u{2061}g\u{206A}h\u{180E}i", false, "abcdefghi"),
            ("tag characters", "flag\u{E0067}\u{E0062}\u{E007F}", false, "flag"),
            ("variation selectors", "B\u{FE0F}\u{E0100}\u{180B}", false, "B"),
            ("private use and replacement", "x\u{E000}\u{F8FF}\u{FFFC}y", false, "xy"),
            ("Hangul fillers", "a\u{3164}b\u{115F}c\u{1160}d\u{FFA0}e", false, "abcde"),
            ("59 stacked marks keep 2", "Z" + String(repeating: "\u{030D}", count: 59) + "a\u{0301}", false, "Z\u{030D}\u{030D}a\u{0301}"),
            ("a mark on nothing", "\u{0301}\u{0301}x", false, "x"),
            ("cut to the length", String(repeating: "a", count: 50), false, String(repeating: "a", count: 39) + "…"),
            ("runs of spaces", "  a   b  ", false, "a b"),
            ("Arabic kept", "مرحبا", false, "مرحبا"),
            ("a name: double quotes go", "Sign-in work” · Version 9 «x» „y“ \"z\" ＂w＂ 「v」", true, "Sign-in work · Version 9 x y z w v"),
            ("a name: single quotes become an apostrophe", "it’s ‘a’ `b´ ‹c›", true, "it's 'a' 'b' 'c'"),
            ("a caption keeps its quotation marks", "“q”", false, "“q”"),
            ("a name of only removed characters", "\u{200D}\u{202E}\u{2066}\u{00AD}\u{FE0F}\u{E0041}\u{3164}", true, ""),
            ("a joined emoji stays joined", "👩\u{200D}💻 and 👨\u{200D}👩\u{200D}👧", true, "👩\u{200D}💻 and 👨\u{200D}👩\u{200D}👧"),
            ("a joiner after a selector between emoji", "🏳\u{FE0F}\u{200D}🌈", true, "🏳\u{200D}🌈"),
            ("a joiner between letters goes", "a\u{200D}b, 👩\u{200D}b, a\u{200D}💻", true, "ab, 👩b, a💻"),
        ]
        for (name, input, isName, expected) in cases {
            let got = isName ? PresentationText.name(input, limit: 40) : PresentationText.plain(input, limit: 40)
            check("\(name)", got == expected, "got \(got.debugDescription), wanted \(expected.debugDescription)")
        }
    }

    await group("a picture is made only as the kind its bytes are, and a large one is never decoded whole for a thumbnail") {
        let small = png(width: 64, height: 48)
        let rep = NSBitmapImageRep(data: small)!
        let bmp = rep.representation(using: .bmp, properties: [:])!
        let gif = rep.representation(using: .gif, properties: [:])!
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\"><rect width=\"20\" height=\"10\"/></svg>".utf8)
        let pdf: Data = {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 10, height: 10)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            return data as Data
        }()
        check("a PNG as a PNG", PresentedPicture.decode(small, mimeType: "image/png", full: false) != nil)
        check("a GIF as a GIF", PresentedPicture.decode(gif, mimeType: "image/gif", full: false) != nil)
        check("a BMP said to be a GIF makes nothing", PresentedPicture.decode(bmp, mimeType: "image/gif", full: false) == nil
              && PresentedPicture.thumbnail(bmp, mimeType: "image/gif", longest: 300) == nil)
        check("a BMP said to be a PNG makes nothing", PresentedPicture.decode(bmp, mimeType: "image/png", full: false) == nil)
        check("a GIF said to be a PNG makes nothing", PresentedPicture.decode(gif, mimeType: "image/png", full: false) == nil)
        check("PNG bytes said to be a GIF make nothing", PresentedPicture.decode(small, mimeType: "image/gif", full: false) == nil)
        check("an SVG said to be a PNG makes nothing", PresentedPicture.decode(svg, mimeType: "image/png", full: false) == nil)
        check("a PDF said to be a JPEG makes nothing", PresentedPicture.decode(pdf, mimeType: "image/jpeg", full: false) == nil)
        check("a PDF said to be an SVG makes nothing", PresentedPicture.svgImage(pdf) == nil)
        check("a PNG said to be an SVG makes nothing", PresentedPicture.svgImage(small) == nil)
        check("an SVG as an SVG", PresentedPicture.svgImage(svg) != nil)
        check("a kind not presented makes nothing", PresentedPicture.decode(bmp, mimeType: "image/bmp", full: false) == nil)

        let large = png(width: 4200, height: 4200)
        let thumbnail = PresentedPicture.thumbnail(large, mimeType: "image/png", longest: 300)
        check("a thumbnail is at most 300 on its longest side", thumbnail.map { max($0.width, $0.height) <= 300 } == true, "\(thumbnail.map { "\($0.width)×\($0.height)" } ?? "none")")
        let shown = PresentedPicture.decode(large, mimeType: "image/png", full: false)
        check("a picture over 4,096 × 4,096 is shown made smaller", shown?.smaller == true && shown.map { max($0.image.width, $0.image.height) <= 4096 } == true,
              "\(shown.map { "\($0.image.width)×\($0.image.height), smaller \($0.smaller)" } ?? "none")")
        let full = PresentedPicture.decode(large, mimeType: "image/png", full: true)
        check("and whole when 100% is asked", full?.smaller == false && full?.image.width == 4200)
    }
}
