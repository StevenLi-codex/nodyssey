import Foundation
import Vision
import AppKit
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
var results:[[String:Any]]=[]
while let url=files.nextObject() as? URL {
    guard url.pathExtension == "png" else { continue }
    do {
        let request=VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection=false
        try VNImageRequestHandler(url:url).perform([request])
        let rows=(request.results ?? []).compactMap { obs -> [String:Any]? in
            guard let text=obs.topCandidates(1).first else { return nil }
            let r=obs.boundingBox
            return ["text":text.string,"confidence":text.confidence,"normalizedBox":[r.minX,r.minY,r.width,r.height]]
        }
        results.append(["path":url.path,"observations":rows])
    } catch { results.append(["path":url.path,"error":String(describing:error)]) }
}
let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
try data.write(to:root.appendingPathComponent("ocr.json"))
print("OCR original PNGs:",results.count)
