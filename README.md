# Mac Vision OCR PDF 

Mac Vision OCR PDF cli is a Swift command-line tool that extracts text from images and generates a searchable PDF.

## Features
- Extracts text using Apple's Vision framework.
- Outputs text as a selectable/searchable PDF.
- Debug mode to visualize recognized text bounding boxes.
- Ensures PDF/A compliance with metadata.

## Requirements
- macOS 12+ (Monterey or later)
- Xcode with Swift support
- Command-line tools for macOS

## Installation
### Build from Source
1. Compile the project:
   ```sh
   swiftc macocrpdf.swift -o macocrpdf 
   ```

## Usage
```sh
./macocrpdf <input_image_path> <output_pdf_path> [--debug]
```

### Examples
- Process a single image:
  ```sh
  ./macocrpdf image.png output.pdf
  ```
- Enable debug mode (shows bounding boxes in terminal and PDF):
  ```sh
  ./macocrpdf image.png output.pdf  --debug
  ```

## License
This project is licensed under the MIT License.

## Contributing
Pull requests are welcome! Please open an issue for any major changes first.

## Acknowledgments
This project uses [Apple's Vision framework for OCR](https://developer.apple.com/documentation/vision/locating-and-displaying-recognized-text) and PDFKit for PDF generation.

