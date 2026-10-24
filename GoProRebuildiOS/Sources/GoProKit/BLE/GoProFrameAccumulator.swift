import Foundation

/// GoPro BLE frame defragmenter.
///
/// Port of `ble/GoProBlePacketAccumulator.kt`. Notifications arrive split across
/// several BLE packets; a start packet carries the total length, continuation
/// packets set bit 7 in their first byte.
public final class GoProFrameAccumulator {
    private var buffer = Data()
    private var expectedLength = -1

    public init() {}

    /// Feed one raw notification packet.
    /// Returns a reassembled frame when complete, `nil` when more fragments are needed.
    public func feed(_ packet: Data) -> Data? {
        guard let firstByte = packet.first else { return nil }
        let first = Int(firstByte)

        // Bit 7 set marks a continuation packet: drop the 1-byte header, append the rest.
        if first & 0x80 != 0 {
            guard expectedLength > 0, packet.count > 1 else { return nil }
            buffer.append(packet.dropFirst())
            if buffer.count >= expectedLength {
                let full = buffer
                reset()
                return full
            }
            return nil
        }

        reset()

        let lengthType = first & 0xE0
        let headerLength: Int
        let totalPayloadLength: Int

        switch lengthType {
        case 0x00:
            // 5-bit length in byte 0.
            headerLength = 1
            totalPayloadLength = first & 0x1F
        case 0x20:
            // 13-bit length across byte 0 and byte 1.
            guard packet.count >= 2 else { return nil }
            headerLength = 2
            totalPayloadLength = ((first & 0x1F) << 8) | Int(packet[packet.startIndex + 1])
        case 0x40:
            // 16-bit length across byte 1 and byte 2.
            guard packet.count >= 3 else { return nil }
            headerLength = 3
            totalPayloadLength = (Int(packet[packet.startIndex + 1]) << 8) | Int(packet[packet.startIndex + 2])
        default:
            headerLength = 0
            totalPayloadLength = packet.count
        }

        expectedLength = totalPayloadLength
        if packet.count > headerLength {
            buffer.append(packet.dropFirst(headerLength))
        }

        if buffer.count >= expectedLength {
            let full = buffer
            reset()
            return full
        }
        return nil
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        expectedLength = -1
    }
}
