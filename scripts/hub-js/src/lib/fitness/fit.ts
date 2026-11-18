/**
 * A minimal FIT decoder: enough of the FIT protocol (Garmin's binary activity
 * format) to read the files the iOS app copies off the watch. Pure functions,
 * no dependencies, so it runs under `node --test`.
 *
 * A file is a header, a stream of records and a CRC. Each record is either a
 * definition (which global message, which fields, their sizes and types, for a
 * local slot 0-15) or data laid out by the slot's last definition. Compressed
 * timestamp headers carry a 5-bit offset from the last full timestamp.
 */

/** Seconds between the Unix epoch and FIT's (1989-12-31 00:00 UTC). */
export const FIT_EPOCH = 631065600;

export type FitValue = number | string | (number | null)[] | null;

export type FitMessage = {
  /** Global message number (18 session, 20 record, 55 monitoring...). */
  num: number;
  /** Field values by field number, already range-checked: invalid values are null. */
  fields: Map<number, FitValue>;
};

const CRC_TABLE = [
  0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
  0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400,
];

export function fitCrc(data: Uint8Array, start = 0, end = data.length, crc = 0): number {
  for (let i = start; i < end; i++) {
    const byte = data[i];
    crc = ((crc >> 4) & 0x0fff) ^ CRC_TABLE[crc & 0xf] ^ CRC_TABLE[byte & 0xf];
    crc = ((crc >> 4) & 0x0fff) ^ CRC_TABLE[crc & 0xf] ^ CRC_TABLE[(byte >> 4) & 0xf];
  }
  return crc;
}

/** Header size 12 or 14, ".FIT", declared length and a whole-file CRC of 0. */
export function isFit(data: Uint8Array): boolean {
  if (data.length < 14 || (data[0] !== 12 && data[0] !== 14)) return false;
  if (String.fromCharCode(...data.subarray(8, 12)) !== ".FIT") return false;
  const size = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(4, true);
  return data.length === data[0] + size + 2 && fitCrc(data) === 0;
}

// Base types by their low 5 bits: size, and a reader that returns null for the type's invalid value.
type BaseType = { size: number; read: (view: DataView, at: number, little: boolean) => number | null };
const valid = (invalid: number) => (value: number) => (value === invalid ? null : value);
const u8 = valid(0xff), s8 = valid(0x7f), s16 = valid(0x7fff), u16 = valid(0xffff), s32 = valid(0x7fffffff), u32 = valid(0xffffffff), z = valid(0);
const big = (invalid: bigint) => (value: bigint) => (value === invalid ? null : Number(value));
const s64 = big(BigInt("0x7fffffffffffffff")), u64 = big(BigInt("0xffffffffffffffff")), u64z = big(BigInt(0));
const float = (value: number) => (Number.isNaN(value) || !Number.isFinite(value) ? null : value);
const BASE_TYPES: Record<number, BaseType> = {
  0: { size: 1, read: (v, a) => u8(v.getUint8(a)) }, // enum
  1: { size: 1, read: (v, a) => s8(v.getInt8(a)) },
  2: { size: 1, read: (v, a) => u8(v.getUint8(a)) },
  3: { size: 2, read: (v, a, l) => s16(v.getInt16(a, l)) },
  4: { size: 2, read: (v, a, l) => u16(v.getUint16(a, l)) },
  5: { size: 4, read: (v, a, l) => s32(v.getInt32(a, l)) },
  6: { size: 4, read: (v, a, l) => u32(v.getUint32(a, l)) },
  8: { size: 4, read: (v, a, l) => float(v.getFloat32(a, l)) },
  9: { size: 8, read: (v, a, l) => float(v.getFloat64(a, l)) },
  10: { size: 1, read: (v, a) => z(v.getUint8(a)) }, // uint8z
  11: { size: 2, read: (v, a, l) => z(v.getUint16(a, l)) },
  12: { size: 4, read: (v, a, l) => z(v.getUint32(a, l)) },
  13: { size: 1, read: (v, a) => u8(v.getUint8(a)) }, // byte
  14: { size: 8, read: (v, a, l) => s64(v.getBigInt64(a, l)) },
  15: { size: 8, read: (v, a, l) => u64(v.getBigUint64(a, l)) },
  16: { size: 8, read: (v, a, l) => u64z(v.getBigUint64(a, l)) },
};

type FieldDef = { num: number; size: number; type: number };
type Definition = { num: number; little: boolean; fields: FieldDef[]; devSize: number };

export class FitError extends Error {}

/**
 * A FIT file the watch is still writing: the header is there, but the
 * declared length or the closing CRC may not be yet. Today's all-day
 * monitoring file looks like this until the watch closes it at midnight.
 */
export function isPartialFit(data: Uint8Array): boolean {
  return data.length > 14 && (data[0] === 12 || data[0] === 14) && String.fromCharCode(...data.subarray(8, 12)) === ".FIT";
}

/**
 * Decodes every data message. Throws FitError on a bad header or CRC, or a
 * record that runs past the data. Unknown base types are skipped by size.
 * With `partial`, a file that isn't closed yet is read up to its last whole
 * record instead of being refused.
 */
export function decodeFit(data: Uint8Array, options: { partial?: boolean } = {}): FitMessage[] {
  const complete = isFit(data);
  if (!complete && !(options.partial && isPartialFit(data))) throw new FitError("not a valid FIT file (header, length or CRC)");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const declared = data[0] + view.getUint32(4, true);
  const end = complete ? declared : Math.min(declared > data[0] ? declared : data.length, data.length);
  const definitions = new Map<number, Definition>();
  const messages: FitMessage[] = [];
  let at = data[0];
  let lastTimestamp = 0;

  const need = (bytes: number) => {
    if (at + bytes > end) throw new FitError("record runs past the end of the data");
  };

  while (at < end) {
    // An open file ends mid-record: keep everything before it.
    if (!complete) {
      try {
        at = readRecord(at);
      } catch (error) {
        if (error instanceof FitError) break;
        throw error;
      }
      continue;
    }
    at = readRecord(at);
  }
  return messages;

  /** Reads one record at `start`; returns where the next one begins. */
  function readRecord(start: number): number {
    at = start;
    const header = data[at++];
    let local: number;
    let compressedOffset: number | null = null;
    if (header & 0x80) {
      local = (header >> 5) & 0x3;
      compressedOffset = header & 0x1f;
    } else {
      local = header & 0x0f;
      if (header & 0x40) {
        need(5);
        const little = data[at + 1] === 0;
        const num = little ? view.getUint16(at + 2, true) : view.getUint16(at + 2, false);
        const count = data[at + 4];
        at += 5;
        need(count * 3);
        const fields: FieldDef[] = [];
        for (let i = 0; i < count; i++, at += 3) fields.push({ num: data[at], size: data[at + 1], type: data[at + 2] & 0x1f });
        let devSize = 0;
        if (header & 0x20) {
          need(1);
          const devCount = data[at++];
          need(devCount * 3);
          for (let i = 0; i < devCount; i++, at += 3) devSize += data[at + 1];
        }
        definitions.set(local, { num, little, fields, devSize });
        return at;
      }
    }

    const definition = definitions.get(local);
    if (!definition) throw new FitError(`data for undefined local message ${local}`);
    const fields = new Map<number, FitValue>();
    for (const field of definition.fields) {
      need(field.size);
      fields.set(field.num, readField(view, at, field, definition.little));
      at += field.size;
    }
    need(definition.devSize);
    at += definition.devSize;

    if (compressedOffset !== null) {
      let timestamp = (lastTimestamp & ~0x1f) + compressedOffset;
      if (compressedOffset < (lastTimestamp & 0x1f)) timestamp += 0x20;
      lastTimestamp = timestamp;
      fields.set(253, timestamp);
    } else {
      const timestamp = fields.get(253);
      if (typeof timestamp === "number") lastTimestamp = timestamp;
    }
    messages.push({ num: definition.num, fields });
    return at;
  }
}

function readField(view: DataView, at: number, field: FieldDef, little: boolean): FitValue {
  if (field.type === 7) {
    const bytes = new Uint8Array(view.buffer, view.byteOffset + at, field.size);
    const zero = bytes.indexOf(0);
    const text = new TextDecoder().decode(zero === -1 ? bytes : bytes.subarray(0, zero));
    return text || null;
  }
  const base = BASE_TYPES[field.type];
  if (!base || field.size % base.size !== 0) return null;
  const values: (number | null)[] = [];
  for (let offset = 0; offset < field.size; offset += base.size) values.push(base.read(view, at + offset, little));
  return values.length === 1 ? values[0] : values;
}

/** A field as a number, or null when missing, invalid or an array. */
export function num(message: FitMessage, field: number, scale = 1): number | null {
  const value = message.fields.get(field);
  return typeof value === "number" ? value / scale : null;
}

/** A FIT timestamp as a Date. */
export function fitDate(seconds: number): Date {
  return new Date((seconds + FIT_EPOCH) * 1000);
}
