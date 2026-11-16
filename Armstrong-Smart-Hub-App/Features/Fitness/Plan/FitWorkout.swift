import Foundation

/// A structured workout, written as a FIT workout file (file type 5) the
/// watch can follow step by step with heart-rate targets: file_id, workout and
/// workout_step messages, per the FIT SDK profile. The CRC is FIT's own, which
/// is the same CRC-16 the GFDI link uses (GarminCRC).
struct FitWorkout: Equatable {
    enum Sport: UInt8 {
        case generic = 0, running = 1, cycling = 2, training = 10, walking = 11

        var title: String {
            switch self {
            case .running: "run"
            case .cycling: "ride"
            case .walking: "walk"
            case .training, .generic: "session"
            }
        }
    }

    enum Intensity: UInt8 { case active = 0, rest = 1, warmup = 2, cooldown = 3, recovery = 4 }

    enum Step: Equatable {
        /// A timed step held between two heart rates (bpm); nil bounds mean no target.
        case timed(name: String, seconds: Int, low: Int?, high: Int?, intensity: Intensity)
        /// Repeat the steps from `fromStep` (index into the list) `times` times in all.
        case repeatFrom(fromStep: Int, times: Int)
    }

    var name: String
    var sport: Sport
    var steps: [Step]

    /// Total time, counting repeats.
    var seconds: Int {
        var total = 0
        for (i, step) in steps.enumerated() {
            switch step {
            case let .timed(_, s, _, _, _): total += s
            case let .repeatFrom(from, times):
                let block = steps[from..<i].reduce(0) { sum, s in
                    if case let .timed(_, sec, _, _, _) = s { return sum + sec }
                    return sum
                }
                total += block * (times - 1)
            }
        }
        return total
    }

    // MARK: Encoding

    private enum Base: UInt8 { case enumeration = 0x00, uint8 = 0x02, string = 0x07, uint16 = 0x84, uint32 = 0x86, uint32z = 0x8C }

    private struct Field { var number: UInt8; var size: UInt8; var base: Base }

    /// FIT time: seconds since 1989-12-31 00:00 UTC.
    private static func fitTime(_ date: Date) -> UInt32 { UInt32(max(0, date.timeIntervalSince1970 - 631_065_600)) }

    func encode(created: Date = .now) -> [UInt8] {
        var body: [UInt8] = []

        func define(local: UInt8, global: UInt16, _ fields: [Field]) {
            body.append(0x40 | local)
            body.append(0)            // reserved
            body.append(0)            // little endian
            body.appendLE(global)
            body.append(UInt8(fields.count))
            for f in fields { body += [f.number, f.size, f.base.rawValue] }
        }
        func string(_ s: String, size: Int) -> [UInt8] {
            var bytes = Array(s.utf8.prefix(size - 1))
            while bytes.count < size { bytes.append(0) }
            return bytes
        }

        // file_id (0): type, manufacturer (255 = development), product, serial, time created.
        define(local: 0, global: 0, [
            Field(number: 0, size: 1, base: .enumeration),
            Field(number: 1, size: 2, base: .uint16),
            Field(number: 2, size: 2, base: .uint16),
            Field(number: 3, size: 4, base: .uint32z),
            Field(number: 4, size: 4, base: .uint32),
        ])
        body.append(0)
        body.append(5)
        body.appendLE(UInt16(255))
        body.appendLE(UInt16(0))
        body.appendLE(UInt32.random(in: 1...UInt32.max - 1))
        body.appendLE(Self.fitTime(created))

        // workout (26): sport, sub sport, number of steps, name.
        let nameSize = 32
        define(local: 1, global: 26, [
            Field(number: 4, size: 1, base: .enumeration),
            Field(number: 11, size: 1, base: .enumeration),
            Field(number: 6, size: 2, base: .uint16),
            Field(number: 8, size: UInt8(nameSize), base: .string),
        ])
        body.append(1)
        body.append(sport.rawValue)
        body.append(0)
        body.appendLE(UInt16(steps.count))
        body += string(name, size: nameSize)

        // workout_step (27): index, name, duration type/value, target type/value, custom low/high, intensity.
        let stepNameSize = 16
        define(local: 2, global: 27, [
            Field(number: 254, size: 2, base: .uint16),
            Field(number: 0, size: UInt8(stepNameSize), base: .string),
            Field(number: 1, size: 1, base: .enumeration),
            Field(number: 2, size: 4, base: .uint32),
            Field(number: 3, size: 1, base: .enumeration),
            Field(number: 4, size: 4, base: .uint32),
            Field(number: 5, size: 4, base: .uint32),
            Field(number: 6, size: 4, base: .uint32),
            Field(number: 7, size: 1, base: .enumeration),
        ])
        let invalid32 = UInt32.max
        for (i, step) in steps.enumerated() {
            body.append(2)
            body.appendLE(UInt16(i))
            switch step {
            case let .timed(stepName, seconds, low, high, intensity):
                body += string(stepName, size: stepNameSize)
                body.append(0)                                  // duration: time
                body.appendLE(UInt32(seconds * 1000))           // in ms
                if let low, let high {
                    body.append(1)                              // target: heart rate
                    body.appendLE(UInt32(0))                    // 0 = custom range, not a zone
                    body.appendLE(UInt32(low + 100))            // bpm + 100
                    body.appendLE(UInt32(high + 100))
                } else {
                    body.append(2)                              // target: open
                    body.appendLE(invalid32)
                    body.appendLE(invalid32)
                    body.appendLE(invalid32)
                }
                body.append(intensity.rawValue)
            case let .repeatFrom(from, times):
                body += string("", size: stepNameSize)
                body.append(6)                                  // repeat until steps complete
                body.appendLE(UInt32(from))                     // the step to go back to
                body.append(2)
                body.appendLE(UInt32(times))                    // how many times in all
                body.appendLE(invalid32)
                body.appendLE(invalid32)
                body.append(Intensity.active.rawValue)
            }
        }

        // 14-byte header with its own CRC, then the records, then the file CRC.
        var file: [UInt8] = [14, 0x20]
        file.appendLE(UInt16(2132))
        file.appendLE(UInt32(body.count))
        file += Array(".FIT".utf8)
        file.appendLE(GarminCRC.compute(file))
        file += body
        file.appendLE(GarminCRC.compute(file))
        return file
    }
}
