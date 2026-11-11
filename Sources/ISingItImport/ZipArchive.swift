import Foundation

/// A minimal read-only ZIP reader (stored and deflated entries), enough for `.mxl`
/// compressed MusicXML. Pure Swift so it behaves the same on macOS and Linux.
struct ZipArchive {
    struct Entry {
        var path: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    let data: [UInt8]
    let entries: [Entry]

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.data = bytes
        // Find the end-of-central-directory record (scan back over a possible comment).
        guard bytes.count >= 22 else { throw ImportError.invalidArchive("file too short") }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ImportError.invalidArchive("no end of central directory") }
        let count = Int(Self.u16(bytes, eocd + 10))
        var offset = Int(Self.u32(bytes, eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Self.u32(bytes, offset) == 0x0201_4B50 else {
                throw ImportError.invalidArchive("bad central directory entry")
            }
            let method = Self.u16(bytes, offset + 10)
            let compressed = Int(Self.u32(bytes, offset + 20))
            let uncompressed = Int(Self.u32(bytes, offset + 24))
            let nameLength = Int(Self.u16(bytes, offset + 28))
            let extraLength = Int(Self.u16(bytes, offset + 30))
            let commentLength = Int(Self.u16(bytes, offset + 32))
            let localOffset = Int(Self.u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else {
                throw ImportError.invalidArchive("truncated entry name")
            }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                path: name, method: method, compressedSize: compressed,
                uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Returns the bytes of an entry, or nil if the path is not in the archive.
    func extract(path: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.path == path }) else { return nil }
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, Self.u32(data, h) == 0x0403_4B50 else {
            throw ImportError.invalidArchive("bad local header for \(path)")
        }
        let start = h + 30 + Int(Self.u16(data, h + 26)) + Int(Self.u16(data, h + 28))
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ImportError.invalidArchive("truncated entry \(path)") }
        let payload = Array(data[start..<end])
        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            var inflater = Inflater(input: payload)
            return Data(try inflater.inflate(expectedSize: entry.uncompressedSize))
        default:
            throw ImportError.invalidArchive("unsupported compression method \(entry.method)")
        }
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Raw DEFLATE decoder (RFC 1951).
struct Inflater {
    private let input: [UInt8]
    private var position = 0
    private var bitBuffer: UInt32 = 0
    private var bitCount = 0
    private var output: [UInt8] = []

    init(input: [UInt8]) { self.input = input }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    mutating func inflate(expectedSize: Int = 0) throws -> [UInt8] {
        output.reserveCapacity(expectedSize)
        var last = false
        while !last {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try fixed()
            case 2: try dynamic()
            default: throw ImportError.invalidArchive("invalid deflate block type")
            }
        }
        return output
    }

    private mutating func bits(_ need: Int) throws -> Int {
        while bitCount < need {
            guard position < input.count else { throw ImportError.invalidArchive("deflate data ended early") }
            bitBuffer |= UInt32(input[position]) << UInt32(bitCount)
            position += 1
            bitCount += 8
        }
        let value = Int(bitBuffer & ((1 << UInt32(need)) - 1))
        bitBuffer >>= UInt32(need)
        bitCount -= need
        return value
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for length in 1..<16 {
            code |= try bits(1)
            let count = h.counts[length]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw ImportError.invalidArchive("invalid Huffman code")
    }

    private mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw ImportError.invalidArchive("truncated stored block") }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        position += 4
        guard position + length <= input.count else { throw ImportError.invalidArchive("truncated stored block") }
        output.append(contentsOf: input[position..<(position + length)])
        position += length
    }

    private mutating func fixed() throws {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        try codes(Huffman(lengths: lengths), Huffman(lengths: [Int](repeating: 5, count: 30)))
    }

    private mutating func dynamic() throws {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { codeLengths[order[i]] = try bits(3) }
        let codeHuffman = Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        while lengths.count < nlen + ndist {
            let symbol = try decode(codeHuffman)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw ImportError.invalidArchive("repeat with no length") }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + (try bits(2))))
            case 17:
                lengths.append(contentsOf: repeatElement(0, count: 3 + (try bits(3))))
            default:
                lengths.append(contentsOf: repeatElement(0, count: 11 + (try bits(7))))
            }
        }
        guard lengths.count == nlen + ndist else { throw ImportError.invalidArchive("too many code lengths") }
        try codes(Huffman(lengths: Array(lengths[0..<nlen])), Huffman(lengths: Array(lengths[nlen...])))
    }

    private mutating func codes(_ lengthCode: Huffman, _ distCode: Huffman) throws {
        while true {
            let symbol = try decode(lengthCode)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < 29 else { throw ImportError.invalidArchive("invalid length symbol") }
                let length = Self.lengthBase[index] + (try bits(Self.lengthExtra[index]))
                let distSymbol = try decode(distCode)
                guard distSymbol < 30 else { throw ImportError.invalidArchive("invalid distance symbol") }
                let distance = Self.distBase[distSymbol] + (try bits(Self.distExtra[distSymbol]))
                guard distance <= output.count else { throw ImportError.invalidArchive("distance too far back") }
                let start = output.count - distance
                for k in 0..<length { output.append(output[start + k]) }
            }
        }
    }
}
