import AppKit
import CoreText
import Foundation
import NaturalLanguage
import PDFKit
import Vision

let fontScaleX = 0.7 // Magic number. Text wont render in PDF unless we scale it down a little bit against bounding box.
let a4PortraitSize = CGSize(width: 595, height: 842) // A4 portrait dimensions in points

// MARK: - Batch Processing Support

enum OCRError: Error {
    case fileLoadFailed(String)
    case textLayerExists
    case ocrProcessingFailed(String)
    case outputWriteFailed(String)
    case lowQualityOCR
}

struct BatchResult {
    var processed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var lowQuality: Int = 0
    var errors: [(String, String)] = []
}

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

func pdfHasTextLayer(pdfURL: URL) -> Bool {
    guard let pdfDoc = PDFDocument(url: pdfURL) else {
        return false
    }

    for pageIndex in 0..<pdfDoc.pageCount {
        guard let page = pdfDoc.page(at: pageIndex) else { continue }
        if let pageContent = page.string, !pageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
    }

    return false
}

func discoverFiles(in directory: String) -> [URL] {
    let fileManager = FileManager.default
    let dirURL = URL(fileURLWithPath: directory)

    guard let contents = try? fileManager.contentsOfDirectory(
        at: dirURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    let supportedExtensions = ["pdf", "png", "jpg", "jpeg"]
    let filtered = contents.filter { url in
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    return filtered.sorted { url1, url2 in
        (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast <
        (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
    }
}

func verifyOCRQuality(text: String, outputPath: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check minimum length
    guard trimmed.count >= 10 else {
        return false
    }

    // Check for alphanumeric characters
    let alphanumericCount = trimmed.filter { $0.isLetter || $0.isNumber }.count
    guard alphanumericCount > 0 else {
        return false
    }

    return true
}

func logToFile(_ message: String, logPath: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    let fileManager = FileManager.default
    let logURL = URL(fileURLWithPath: logPath)

    if !fileManager.fileExists(atPath: logPath) {
        fileManager.createFile(atPath: logPath, contents: nil)
    }

    if let fileHandle = try? FileHandle(forWritingTo: logURL) {
        fileHandle.seekToEndOfFile()
        if let data = logMessage.data(using: .utf8) {
            fileHandle.write(data)
        }
        fileHandle.closeFile()
    }
}

func setupInplaceMode(inputDir: String) -> String? {
    let fileManager = FileManager.default

    // Resolve relative paths (like ".") to absolute paths to get the actual directory name
    let absolutePath = (inputDir as NSString).standardizingPath
    let inputURL = URL(fileURLWithPath: absolutePath)
    let parentDir = inputURL.deletingLastPathComponent()
    let dirName = inputURL.lastPathComponent

    let sourceDir = parentDir.appendingPathComponent("\(dirName)-source").path

    // Check if backup already exists
    if fileManager.fileExists(atPath: sourceDir) {
        print("Error: Backup directory already exists at \(sourceDir)")
        return nil
    }

    // Create backup directory for processed files only
    do {
        try fileManager.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)
        print("Created backup directory at \(sourceDir)")
    } catch {
        print("Error: Failed to create backup directory: \(error.localizedDescription)")
        return nil
    }

    // Return backup path - we'll move files individually during processing
    // Only files that are actually processed will be backed up
    // Skipped files, subdirectories, and other content stay in place
    return sourceDir
}

func processImageToPDF(cgImage: CGImage, pdfContext: CGContext, pageBounds: CGRect, debug: Bool) -> String {
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
        pdfContext.setTextDrawingMode(.invisible)
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

    return extractedText
}

func processPDF(from pdfPath: String, outputPDFPath: String, debug: Bool = false) -> Result<String, OCRError> {
    let pdfURL = URL(fileURLWithPath: pdfPath)

    guard let inputPDF = PDFDocument(url: pdfURL) else {
        if debug {
            print("Error: Unable to load PDF at \(pdfPath)")
        }
        return .failure(.fileLoadFailed("Unable to load PDF"))
    }

    if pdfHasTextLayer(pdfURL: pdfURL) {
        if debug {
            print("PDF already has a text layer. Skipping.")
        }
        return .failure(.textLayerExists)
    }

    if debug {
        print("Processing PDF with \(inputPDF.pageCount) page(s)...")
    }

    var allExtractedText = ""
    let pdfData = NSMutableData()
    guard let pdfConsumer = CGDataConsumer(data: pdfData) else {
        return .failure(.ocrProcessingFailed("Failed to create PDF consumer"))
    }

    var firstPageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
    if let firstPage = inputPDF.page(at: 0) {
        firstPageBounds = firstPage.bounds(for: .mediaBox)
    }

    let pdfMetaData: [CFString: Any] = [
        kCGPDFContextCreator: "Mac Vision OCR PDF",
        kCGPDFContextTitle: "OCR Generated PDF",
        kCGPDFContextSubject: "Text extracted from images",
    ]

    guard let pdfContext = CGContext(
        consumer: pdfConsumer, mediaBox: &firstPageBounds, pdfMetaData as CFDictionary)
    else {
        return .failure(.ocrProcessingFailed("Failed to create PDF context"))
    }

    for pageIndex in 0..<inputPDF.pageCount {
        guard let page = inputPDF.page(at: pageIndex) else { continue }

        var pageBounds = page.bounds(for: .mediaBox)
        let scaleFactor = max(
            pageBounds.width / a4PortraitSize.width,
            pageBounds.height / a4PortraitSize.height
        )

        if scaleFactor > 1 {
            pageBounds.size.width = pageBounds.width / scaleFactor
            pageBounds.size.height = pageBounds.height / scaleFactor
        }

        // Render page at high resolution (2x for retina quality)
        let renderScale: CGFloat = 2.0
        let renderSize = CGSize(
            width: page.bounds(for: .mediaBox).width * renderScale,
            height: page.bounds(for: .mediaBox).height * renderScale
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            if debug {
                print("Warning: Unable to create rendering context for page \(pageIndex + 1)")
            }
            continue
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))

        context.scaleBy(x: renderScale, y: renderScale)

        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            if debug {
                print("Warning: Unable to get CGImage from page \(pageIndex + 1)")
            }
            continue
        }

        if debug {
            print("Processing page \(pageIndex + 1)/\(inputPDF.pageCount)...")
        }

        pdfContext.beginPage(mediaBox: &pageBounds)
        let pageText = processImageToPDF(cgImage: cgImage, pdfContext: pdfContext, pageBounds: pageBounds, debug: debug)
        allExtractedText.append(pageText)
        pdfContext.endPage()
    }

    pdfContext.closePDF()

    do {
        try pdfData.write(to: URL(fileURLWithPath: outputPDFPath))
        if debug {
            print("PDF saved at \(outputPDFPath)")
        }
        return .success(allExtractedText)
    } catch {
        if debug {
            print("Error: Failed to write PDF to file \(outputPDFPath)")
        }
        return .failure(.outputWriteFailed(error.localizedDescription))
    }
}

func recognizeText(from imagePath: String, outputPDFPath: String, debug: Bool = false) -> Result<String, OCRError> {
    guard let image = NSImage(contentsOfFile: imagePath),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        if debug {
            print("Error: Unable to load image at \(imagePath)")
        }
        return .failure(.fileLoadFailed("Unable to load image"))
    }

    var pageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    let scaleFactor = max(
        CGFloat(cgImage.width) / a4PortraitSize.width, CGFloat(cgImage.height) / a4PortraitSize.height)
    if scaleFactor > 1 {
        pageBounds.size.width = CGFloat(cgImage.width) / scaleFactor
        pageBounds.size.height = CGFloat(cgImage.height) / scaleFactor
    } else {
        pageBounds.size = CGSize(width: cgImage.width, height: cgImage.height)
    }

    let pdfMetaData: [CFString: Any] = [
        kCGPDFContextCreator: "Mac Vision OCR PDF",
        kCGPDFContextTitle: "OCR Generated PDF",
        kCGPDFContextSubject: "Text extracted from image",
    ]

    let pdfData = NSMutableData()
    guard let pdfConsumer = CGDataConsumer(data: pdfData) else {
        return .failure(.ocrProcessingFailed("Failed to create PDF consumer"))
    }
    guard
        let pdfContext = CGContext(
            consumer: pdfConsumer, mediaBox: &pageBounds, pdfMetaData as CFDictionary)
    else {
        return .failure(.ocrProcessingFailed("Failed to create PDF context"))
    }

    pdfContext.beginPage(mediaBox: &pageBounds)
    let extractedText = processImageToPDF(cgImage: cgImage, pdfContext: pdfContext, pageBounds: pageBounds, debug: debug)
    pdfContext.endPage()
    pdfContext.closePDF()

    do {
        try pdfData.write(to: URL(fileURLWithPath: outputPDFPath))
        if debug {
            print("PDF saved at \(outputPDFPath)")
        }
        return .success(extractedText)
    } catch {
        if debug {
            print("Error: Failed to write PDF to file \(outputPDFPath)")
        }
        return .failure(.outputWriteFailed(error.localizedDescription))
    }
}

func processBatch(inputDir: String, outputDir: String, inplace: Bool, backupDir: String?, debug: Bool) -> BatchResult {
    var result = BatchResult()
    let fileManager = FileManager.default
    let logPath = "\(fileManager.currentDirectoryPath)/ocr-process.log"
    let startTime = Date()

    logToFile("=== OCR Batch Processing Started ===", logPath: logPath)
    logToFile("Input directory: \(inputDir)", logPath: logPath)
    logToFile("Output directory: \(outputDir)", logPath: logPath)
    logToFile("Inplace mode: \(inplace)", logPath: logPath)
    if let backup = backupDir {
        logToFile("Backup directory: \(backup)", logPath: logPath)
    }

    // Discover files
    let actualFiles = discoverFiles(in: inputDir)

    guard !actualFiles.isEmpty else {
        print("No supported files found in directory")
        logToFile("No supported files found", logPath: logPath)
        return result
    }

    logToFile("Found \(actualFiles.count) files to process", logPath: logPath)
    print("Found \(actualFiles.count) file(s) to process\n")

    // Create output directory if needed
    if !fileManager.fileExists(atPath: outputDir) {
        do {
            try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            logToFile("Created output directory: \(outputDir)", logPath: logPath)
        } catch {
            print("Error: Failed to create output directory: \(error.localizedDescription)")
            logToFile("Failed to create output directory: \(error.localizedDescription)", logPath: logPath)
            return result
        }
    }

    // Process each file
    for (index, fileURL) in actualFiles.enumerated() {
        let fileName = fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let baseNameWithoutExt = fileURL.deletingPathExtension().lastPathComponent

        print("Processing \(index + 1)/\(actualFiles.count): \(fileName)")
        logToFile("Processing file \(index + 1)/\(actualFiles.count): \(fileName)", logPath: logPath)

        // Determine output path
        let outputFileName = "\(baseNameWithoutExt).pdf"
        let outputPath = "\(outputDir)/\(outputFileName)"

        // In inplace mode, check if file will be skipped before moving it
        if inplace && fileExtension == "pdf" && pdfHasTextLayer(pdfURL: fileURL) {
            // File already has text layer - leave it in place, no backup needed
            result.skipped += 1
            print("  Skipped (already has text layer)")
            logToFile("Skipped \(fileName): already has text layer (left in place)", logPath: logPath)
            print("")
            continue
        }

        // In inplace mode, move file to backup before processing
        var sourceFilePath = fileURL.path
        if inplace, let backup = backupDir {
            let backupFilePath = "\(backup)/\(fileName)"
            do {
                try fileManager.moveItem(atPath: fileURL.path, toPath: backupFilePath)
                sourceFilePath = backupFilePath
                logToFile("Backed up \(fileName) for processing", logPath: logPath)
            } catch {
                result.failed += 1
                result.errors.append((fileName, "Failed to backup file: \(error.localizedDescription)"))
                print("  Failed: Could not backup file")
                logToFile("Failed to backup \(fileName): \(error.localizedDescription)", logPath: logPath)
                print("")
                continue
            }
        }

        // Process the file (from backup location in inplace mode, original location otherwise)
        let processResult: Result<String, OCRError>

        if fileExtension == "pdf" {
            processResult = processPDF(from: sourceFilePath, outputPDFPath: outputPath, debug: debug)
        } else {
            processResult = recognizeText(from: sourceFilePath, outputPDFPath: outputPath, debug: debug)
        }

        // Handle result
        switch processResult {
        case .success(let text):
            result.processed += 1
            logToFile("Successfully processed: \(fileName)", logPath: logPath)

            // Verify quality
            if !verifyOCRQuality(text: text, outputPath: outputPath) {
                result.lowQuality += 1
                print("  Warning: Low quality OCR detected")
                logToFile("Warning: Low quality OCR for \(fileName)", logPath: logPath)
            }

        case .failure(let error):
            switch error {
            case .textLayerExists:
                // This should not happen now in inplace mode (we check before moving)
                // but keep it for non-inplace mode
                result.skipped += 1
                print("  Skipped (already has text layer)")
                logToFile("Skipped \(fileName): already has text layer", logPath: logPath)

            case .fileLoadFailed(let msg):
                result.failed += 1
                result.errors.append((fileName, "Unable to load file: \(msg)"))
                print("  Failed: Unable to load file")
                logToFile("Failed \(fileName): \(msg)", logPath: logPath)

            case .ocrProcessingFailed(let msg):
                result.failed += 1
                result.errors.append((fileName, "OCR processing failed: \(msg)"))
                print("  Failed: OCR processing failed")
                logToFile("Failed \(fileName): \(msg)", logPath: logPath)

            case .outputWriteFailed(let msg):
                result.failed += 1
                result.errors.append((fileName, "Failed to write output: \(msg)"))
                print("  Failed: Could not write output file")
                logToFile("Failed \(fileName): \(msg)", logPath: logPath)

            case .lowQualityOCR:
                result.lowQuality += 1
                print("  Warning: Low quality OCR")
                logToFile("Warning: Low quality OCR for \(fileName)", logPath: logPath)
            }
        }

        print("")  // Blank line between files
    }

    let duration = Date().timeIntervalSince(startTime)
    logToFile("=== OCR Batch Processing Completed ===", logPath: logPath)
    logToFile("Total time: \(Int(duration)) seconds", logPath: logPath)

    // Print summary
    print("=== OCR Processing Complete ===")
    print("Processed: \(result.processed) file(s)")
    print("Skipped:   \(result.skipped) file(s) (already have text layer)")
    print("Failed:    \(result.failed) file(s)")
    if result.lowQuality > 0 {
        print("Low Quality: \(result.lowQuality) file(s) (warnings)")
    }
    print("Total Time: \(Int(duration)) seconds")

    if !result.errors.isEmpty {
        print("\nFailed files:")
        for (fileName, errorMsg) in result.errors {
            print("  - \(fileName): \(errorMsg)")
        }
    }

    print("\nSee ocr-process.log for details.")

    return result
}

// MARK: - Main Entry Point

if CommandLine.arguments.count < 2 {
    print("Usage:")
    print("  Single file:  macocrpdf <input_file> <output_pdf> [--debug]")
    print("  Directory:    macocrpdf <input_dir> [<output_dir>] [--inplace] [--debug]")
    print("")
    print("Single file mode:")
    print("  Supports image files (PNG, JPG, etc.) and PDF files")
    print("  PDF files with existing text layers will be skipped")
    print("")
    print("Directory mode:")
    print("  Default:       Creates <input_dir>-ocr/ with processed files")
    print("  Custom output: Uses specified output directory")
    print("  --inplace:     Moves originals to <input_dir>-source/, replaces with OCR versions")
    exit(1)
}

let fileManager = FileManager.default
let inputPath = CommandLine.arguments[1]
let debugMode = CommandLine.arguments.contains("--debug")
let inplaceMode = CommandLine.arguments.contains("--inplace")

var isDirectory: ObjCBool = false
fileManager.fileExists(atPath: inputPath, isDirectory: &isDirectory)

if isDirectory.boolValue {
    // Directory mode
    var outputDir: String

    if inplaceMode {
        // Check if user specified both output directory and --inplace (mutually exclusive)
        if CommandLine.arguments.count >= 3 && !CommandLine.arguments[2].hasPrefix("--") {
            print("Error: Cannot use custom output directory with --inplace flag")
            print("--inplace processes files in the original directory")
            print("Remove either the output directory or the --inplace flag")
            exit(1)
        }

        // Setup inplace mode: create backup directory
        guard let backupDir = setupInplaceMode(inputDir: inputPath) else {
            exit(1)
        }

        // Process in place: files stay in original directory
        // Only files that are processed get moved to backup first
        // Skipped files and subdirectories remain untouched
        _ = processBatch(inputDir: inputPath, outputDir: inputPath, inplace: true, backupDir: backupDir, debug: debugMode)

    } else {
        // Check if second argument is provided and is not a flag
        if CommandLine.arguments.count >= 3 && !CommandLine.arguments[2].hasPrefix("--") {
            // Custom output directory
            outputDir = CommandLine.arguments[2]
        } else {
            // Default: add -ocr suffix to input directory name
            // Resolve relative paths (like ".") to get actual directory name
            let absolutePath = (inputPath as NSString).standardizingPath
            let inputURL = URL(fileURLWithPath: absolutePath)
            let parentDir = inputURL.deletingLastPathComponent()
            let dirName = inputURL.lastPathComponent
            outputDir = parentDir.appendingPathComponent("\(dirName)-ocr").path
        }

        _ = processBatch(inputDir: inputPath, outputDir: outputDir, inplace: false, backupDir: nil, debug: debugMode)
    }

} else {
    // Single file mode (backward compatible)
    if CommandLine.arguments.count < 3 {
        print("Error: Single file mode requires output path")
        print("Usage: macocrpdf <input_file> <output_pdf> [--debug]")
        exit(1)
    }

    let outputPDFPath = CommandLine.arguments[2]
    let fileExtension = (inputPath as NSString).pathExtension.lowercased()

    let result: Result<String, OCRError>
    if fileExtension == "pdf" {
        result = processPDF(from: inputPath, outputPDFPath: outputPDFPath, debug: debugMode)
    } else {
        result = recognizeText(from: inputPath, outputPDFPath: outputPDFPath, debug: debugMode)
    }

    // Handle result for single file mode
    switch result {
    case .success:
        print("Processing complete!")
    case .failure(let error):
        switch error {
        case .textLayerExists:
            print("PDF already has a text layer. Skipping.")
        case .fileLoadFailed(let msg):
            print("Error: Unable to load file: \(msg)")
            exit(1)
        case .ocrProcessingFailed(let msg):
            print("Error: OCR processing failed: \(msg)")
            exit(1)
        case .outputWriteFailed(let msg):
            print("Error: Failed to write output: \(msg)")
            exit(1)
        case .lowQualityOCR:
            print("Warning: Low quality OCR detected")
        }
    }
}
