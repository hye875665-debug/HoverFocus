import Foundation
import ImageIO

@main
struct MakeICNS {
  static func main() throws {
    guard CommandLine.arguments.count >= 4 else {
      throw IconError.usage
    }
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let inputURLs = CommandLine.arguments.dropFirst(2).map(URL.init(fileURLWithPath:))
    var chunks: [(size: Int, type: String, data: Data)] = []
    for inputURL in inputURLs {
      guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
        width == height,
        let type = Self.chunkType(for: width)
      else { throw IconError.cannotRead(inputURL.path) }
      chunks.append((width, type, try Data(contentsOf: inputURL)))
    }

    var body = Data()
    for chunk in chunks.sorted(by: { $0.size < $1.size }) {
      body.append(chunk.type.data(using: .ascii)!)
      body.appendBigEndian(UInt32(chunk.data.count + 8))
      body.append(chunk.data)
    }
    var result = Data("icns".utf8)
    result.appendBigEndian(UInt32(body.count + 8))
    result.append(body)
    try result.write(to: outputURL, options: .atomic)
  }

  static func chunkType(for pixelSize: Int) -> String? {
    switch pixelSize {
    case 16: "icp4"
    case 32: "icp5"
    case 64: "icp6"
    case 128: "ic07"
    case 256: "ic08"
    case 512: "ic09"
    case 1_024: "ic10"
    default: nil
    }
  }

  enum IconError: Error {
    case usage
    case cannotRead(String)
  }
}

extension Data {
  mutating func appendBigEndian(_ value: UInt32) {
    var encoded = value.bigEndian
    Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
  }
}
