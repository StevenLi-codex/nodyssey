import Foundation
import NodysseyNativeCore

/// This exact callback is installed on NativeRichTextActions.onImage.
enum ContentImageGallery {
    static func onImage(value: JSONValue, open: @escaping (String, [String: JSONValue]) -> Void) -> (String, String?) -> Void {
        { url, _ in
            let urls = contentImageURLs(value)
            // Stickers (and any future image-like node) may be outside this gallery.
            // Never substitute index zero of unrelated images for the actual click.
            let index = urls.firstIndex(of: url)
            open("ImageViewer", ["urls": .array((index == nil ? [url] : urls).map(JSONValue.string)), "index": .integer(Int64(index ?? 0))])
        }
    }
}

private func contentImageURLs(_ value: JSONValue) -> [String] {
    var result: [String] = []
    func walk(_ value: JSONValue) {
        if let object = value.object {
            if ["img", "iimg"].contains(object["type"]?.string ?? ""), let url = object["url"]?.string, !result.contains(url) { result.append(url) }
            for key in ["inlines", "children", "tabs", "items", "cells"] { if let nested = object[key] { walk(nested) } }
        } else if let array = value.array { array.forEach(walk) }
    }
    walk(value)
    return result
}
