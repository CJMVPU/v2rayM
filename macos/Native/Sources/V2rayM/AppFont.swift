import SwiftUI
import CoreText

enum AppFont {
    static let postScriptName = "LXGWWenKaiMono-Medium"

    static func register() {
        guard let url = Bundle.module.url(forResource: postScriptName, withExtension: "ttf", subdirectory: "Fonts") else {
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func size(_ points: CGFloat) -> Font {
        .custom(postScriptName, fixedSize: points)
    }

    static let body = size(13)
    static let title = size(17)
    static let caption = size(11)
}
