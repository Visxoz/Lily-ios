import Foundation

/// Just the protobuf Canvas and Home's tokens need; malformed or hostile bytes give nil rather than trapping.
enum Protobuf {
    enum Value {
        case varint(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    static func fields(of message: ArraySlice<UInt8>) -> [(number: UInt64, value: Value)]? {
        guard let entries = entries(of: message) else { return nil }
        return entries.compactMap { entry in
            switch entry.wireType {
            case 0:
                var index = entry.range.lowerBound
                return varint(message, &index).map { (entry.number, .varint($0)) }
            case 2:
                return (entry.number, .bytes(message[entry.range]))
            default:
                return nil
            }
        }
    }

    /// Where field `number`'s first value lies, in `message`'s indices.
    static func range(of number: UInt64, in message: ArraySlice<UInt8>) -> Range<Int>? {
        entries(of: message)?.first { $0.number == number }?.range
    }

    private static func entries(of message: ArraySlice<UInt8>) -> [(number: UInt64, wireType: UInt64, range: Range<Int>)]? {
        var entries: [(number: UInt64, wireType: UInt64, range: Range<Int>)] = []
        var index = message.startIndex
        while index < message.endIndex {
            guard let key = varint(message, &index) else { return nil }
            var start = index
            switch key & 7 {
            case 0:
                guard varint(message, &index) != nil else { return nil }
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard message.endIndex - index >= width else { return nil }
                index += width
            case 2:
                guard let length = varint(message, &index), length <= UInt64(message.endIndex - index) else { return nil }
                start = index
                index += Int(length)
            default:
                return nil
            }
            entries.append((key >> 3, key & 7, start..<index))
        }
        return entries
    }

    /// At most ten bytes, as a 64-bit value takes.
    static func varint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 70, by: 7) {
            guard index < bytes.endIndex else { return nil }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
        }
        return nil
    }

    /// A length-delimited field, as every field Canvas is sent is.
    static func field(_ number: UInt8, _ value: Data) -> Data {
        var data = Data([number << 3 | 2])
        var length = value.count
        while length >= 0x80 {
            data.append(UInt8(length & 0x7f) | 0x80)
            length >>= 7
        }
        data.append(UInt8(length))
        return data + value
    }
}
