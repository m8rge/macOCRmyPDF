import AppKit
import CoreText
import Foundation
import NaturalLanguage
import PDFKit
import Vision

let fontScaleX = 0.7 // Magic number. Text wont render in PDF unless we scale it down a little bit against bounding box.
let a4PortraitSize = CGSize(width: 595, height: 842) // A4 portrait dimensions in points

func extractTitle(from text: String) -> String {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    var title = "OCR Generated PDF"

    tagger.enumerateTags(
        in: text.startIndex..<text.endIndex, unit: .sentence, scheme: .nameType,
        options: [.omitOther, .joinNames]
    ) { tag, tokenRange in
        if let tag = tag, tag == .organizationName || tag == .personalName || tag == .placeName {
            title = String(text[tokenRange])
            return false  // Stop after finding the first key phrase
        }
        return true
    }

    return title
}

func recognizeText(from imagePath: String, outputPDFPath: String, debug: Bool = false) {
    guard let image = NSImage(contentsOfFile: imagePath),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        print("Error: Unable to load image at \(imagePath)")
        return
    }

    var pageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    // Check if the image exceeds A4 size and scale it down if necessary
    let scaleFactor = max(
        CGFloat(cgImage.width) / a4PortraitSize.width, CGFloat(cgImage.height) / a4PortraitSize.height)
    if scaleFactor > 1 {
        pageBounds.size.width = CGFloat(cgImage.width) / scaleFactor
        pageBounds.size.height = CGFloat(cgImage.height) / scaleFactor
    } else {
        pageBounds.size = CGSize(width: cgImage.width, height: cgImage.height)
    }

    var extractedText = ""

    let request = VNRecognizeTextRequest { request, error in
        guard let results = request.results as? [VNRecognizedTextObservation], error == nil else {
            print("Error: OCR processing failed: \(error?.localizedDescription ?? "Unknown error")")
            return
        }

        for observation in results {
            if let topCandidate = observation.topCandidates(1).first {
                extractedText.append(topCandidate.string + " ")
            }
        }
    }

    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = true
    request.recognitionLevel = .accurate

    let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try requestHandler.perform([request])
    } catch {
        print("Error: VNImageRequestHandler failed with error: \(error)")
    }

    let pdfTitle = extractTitle(from: extractedText)
    let pdfMetaData: [CFString: Any] = [
        kCGPDFContextCreator: "Mac Vision OCR PDF",
        kCGPDFContextTitle: pdfTitle,
        kCGPDFContextSubject: "Text extracted from image",
    ]

    let pdfData = NSMutableData()
    guard let pdfConsumer = CGDataConsumer(data: pdfData) else { return }
    guard
        let pdfContext = CGContext(
            consumer: pdfConsumer, mediaBox: &pageBounds, pdfMetaData as CFDictionary)
    else { return }

    pdfContext.beginPage(mediaBox: &pageBounds)
    pdfContext.draw(cgImage, in: pageBounds)

    for observation in request.results ?? [] {
        guard let topCandidate = observation.topCandidates(1).first else { continue }
        let normalizedRect = observation.boundingBox
        let textRect = VNImageRectForNormalizedRect(normalizedRect, Int(pageBounds.size.width), Int(pageBounds.size.height))

        if debug {
            pdfContext.setStrokeColor(NSColor.orange.cgColor)
            pdfContext.stroke(textRect)
            print("Detected text: \(topCandidate.string) at \(textRect)")
        }

        let text = topCandidate.string
        let attributedString = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                .foregroundColor: NSColor.black.cgColor,
            ]
        )

        pdfContext.saveGState()
        let widthScale = textRect.width / attributedString.size().width
        let heightScale = textRect.height / attributedString.size().height * fontScaleX
        pdfContext.translateBy(x: textRect.origin.x, y: textRect.origin.y)
        pdfContext.scaleBy(x: widthScale, y: heightScale)
        pdfContext.setLineWidth(1.0 / max(widthScale, heightScale))

        let textPath = CGMutablePath()
        textPath.addRect(
            CGRect(
                x: 0, y: 0, width: attributedString.size().width,
                height: attributedString.size().height / fontScaleX))
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let textFrame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, attributedString.length), textPath, nil)
        CTFrameDraw(textFrame, pdfContext)
        pdfContext.restoreGState()
    }

    pdfContext.endPage()
    pdfContext.closePDF()

    do {
        try pdfData.write(to: URL(fileURLWithPath: outputPDFPath))
        print("PDF saved at \(outputPDFPath)")
    } catch {
        print("Error: Failed to write PDF to file \(outputPDFPath)")
    }
}

if CommandLine.arguments.count < 3 {
    print("Usage: macocrpdf <input_image_path> <output_pdf_path> [--debug]")
    exit(1)
}

let inputImagePath = CommandLine.arguments[1]
let outputPDFPath = CommandLine.arguments[2]
let debugMode = CommandLine.arguments.contains("--debug")
recognizeText(from: inputImagePath, outputPDFPath: outputPDFPath, debug: debugMode)
