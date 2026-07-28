//
//  AgentHistoryBoundedFileReader.swift
//  Pine
//
//  Size-bounded descriptor reads for verified Agent History state.
//

import Darwin
import Foundation

/// Reads a regular-file descriptor without trusting the live file size to
/// remain stable. The recorded byte count is the allocation/read ceiling:
/// replacements that are already oversized fail at the first `fstat`, while
/// an append racing the read is detected by the single extra byte.
nonisolated enum AgentHistoryBoundedFileReader {
    private static let chunkSize = 64 * 1_024

    static func readExact(
        descriptor: Int32,
        expectedByteCount: UInt64,
        afterInitialStat: (() throws -> Void)? = nil
    ) throws -> Data {
        guard expectedByteCount < UInt64(Int.max) else {
            throw AgentHistoryBoundedFileReadError.unsupportedByteCount(
                expectedByteCount
            )
        }

        try validateSize(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        )
        try afterInitialStat?()

        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw AgentHistoryBoundedFileReadError.posixFailure(errno)
        }

        let expectedCount = Int(expectedByteCount)
        let readLimit = expectedCount + 1
        var result = Data()
        result.reserveCapacity(min(expectedCount, chunkSize))
        var buffer = [UInt8](
            repeating: 0,
            count: min(readLimit, chunkSize)
        )

        while result.count < readLimit {
            let requested = min(buffer.count, readLimit - result.count)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if readCount < 0, errno == EINTR {
                continue
            }
            guard readCount >= 0 else {
                throw AgentHistoryBoundedFileReadError.posixFailure(errno)
            }
            guard readCount > 0 else { break }
            result.append(contentsOf: buffer.prefix(readCount))
        }

        try validateSize(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        )
        guard result.count == expectedCount else {
            throw AgentHistoryBoundedFileReadError.byteCountMismatch(
                expected: expectedByteCount,
                actualAtMost: UInt64(result.count)
            )
        }
        return result
    }

    private static func validateSize(
        descriptor: Int32,
        expectedByteCount: UInt64
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AgentHistoryBoundedFileReadError.posixFailure(errno)
        }
        guard info.st_size >= 0,
              UInt64(info.st_size) == expectedByteCount else {
            throw AgentHistoryBoundedFileReadError.byteCountMismatch(
                expected: expectedByteCount,
                actualAtMost: info.st_size < 0 ? 0 : UInt64(info.st_size)
            )
        }
    }
}

nonisolated enum AgentHistoryBoundedFileReadError: Error, Equatable {
    case unsupportedByteCount(UInt64)
    case byteCountMismatch(expected: UInt64, actualAtMost: UInt64)
    case posixFailure(Int32)
}
