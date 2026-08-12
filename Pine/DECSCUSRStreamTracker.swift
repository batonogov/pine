//
//  DECSCUSRStreamTracker.swift
//  Pine
//
//  Bounded recognition of cursor-shape control sequences in PTY output.
//

import Foundation

/// Tracks only grammatically valid `CSI Ps SP q` (DECSCUSR) commands.
///
/// The state is intentionally fixed-size: control-string payloads, parameter
/// text, and malformed sequences are never buffered. Keeping this parser
/// separate from SwiftTerm lets Pine distinguish the standard `Ps = 0`
/// "restore the user's default" command from an explicit block request while
/// still forwarding every byte to SwiftTerm unchanged.
nonisolated struct DECSCUSRStreamTracker: Sendable {
    enum Directive: Equatable, Sendable {
        case preferred
        case explicit(parameter: Int)
    }

    private enum State: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiParameter
        case csiIntermediate
        case csiIgnore
        case controlString(allowsBellTermination: Bool)
        case controlStringEscape(allowsBellTermination: Bool)
    }

    private enum CSIParameter: Sendable {
        case omitted
        case value(Int)
        case invalid
    }

    private var state = State.ground
    private var csiParameter = CSIParameter.omitted
    private var csiHasSingleSpaceIntermediate = false

    /// Consumes one arbitrary PTY chunk and returns its last supported
    /// DECSCUSR directive. Parser state survives chunk boundaries.
    mutating func consume(_ bytes: ArraySlice<UInt8>) -> Directive? {
        var latestDirective: Directive?

        for byte in bytes {
            switch state {
            case .controlString(let allowsBellTermination):
                consumeControlStringByte(
                    byte,
                    allowsBellTermination: allowsBellTermination
                )
            case .controlStringEscape(let allowsBellTermination):
                consumeControlStringEscapeByte(
                    byte,
                    allowsBellTermination: allowsBellTermination
                )
            default:
                if consumeAnywhereControl(byte) {
                    continue
                }
                consumeSequenceByte(byte, latestDirective: &latestDirective)
            }
        }

        return latestDirective
    }

    /// Handles controls that cancel or start a sequence from any non-string
    /// state. C1 controls are treated as controls, never as UTF-8 payload.
    private mutating func consumeAnywhereControl(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x1B: // ESC
            state = .escape
        case 0x9B: // C1 CSI
            beginCSI()
        case 0x90, 0x98, 0x9E, 0x9F: // DCS, SOS, PM, APC
            state = .controlString(allowsBellTermination: false)
        case 0x9D: // C1 OSC
            state = .controlString(allowsBellTermination: true)
        case 0x18, 0x1A, 0x9C: // CAN, SUB, C1 ST
            state = .ground
        case 0x80...0x9F:
            state = .ground
        default:
            return false
        }
        return true
    }

    private mutating func consumeSequenceByte(
        _ byte: UInt8,
        latestDirective: inout Directive?
    ) {
        switch state {
        case .ground:
            break
        case .escape:
            consumeEscapeByte(byte)
        case .escapeIntermediate:
            consumeEscapeIntermediateByte(byte)
        case .csiParameter:
            consumeCSIParameterByte(byte, latestDirective: &latestDirective)
        case .csiIntermediate:
            consumeCSIIntermediateByte(byte, latestDirective: &latestDirective)
        case .csiIgnore:
            consumeCSIIgnoreByte(byte)
        case .controlString, .controlStringEscape:
            // These states are handled before the anywhere-control path.
            break
        }
    }

    private mutating func consumeEscapeByte(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [
            beginCSI()
        case 0x5D: // ] (OSC)
            state = .controlString(allowsBellTermination: true)
        case 0x50, 0x58, 0x5E, 0x5F: // P (DCS), X (SOS), ^ (PM), _ (APC)
            state = .controlString(allowsBellTermination: false)
        case 0x20...0x2F:
            state = .escapeIntermediate
        case 0x00...0x1F, 0x7F:
            // Executable C0 controls and DEL do not end ESC collection.
            break
        default:
            state = .ground
        }
    }

    private mutating func consumeEscapeIntermediateByte(_ byte: UInt8) {
        switch byte {
        case 0x20...0x2F, 0x00...0x1F, 0x7F:
            break
        default:
            state = .ground
        }
    }

    private mutating func beginCSI() {
        state = .csiParameter
        csiParameter = .omitted
        csiHasSingleSpaceIntermediate = false
    }

    private mutating func consumeCSIParameterByte(
        _ byte: UInt8,
        latestDirective: inout Directive?
    ) {
        switch byte {
        case 0x30...0x39:
            appendCSIDigit(Int(byte - 0x30))
        case 0x3A...0x3F:
            // Subparameters, separators, and private prefixes are not the
            // single numeric parameter accepted by Pine.
            csiParameter = .invalid
        case 0x20...0x2F:
            state = .csiIntermediate
            csiHasSingleSpaceIntermediate = byte == 0x20
        case 0x40...0x7E:
            finishCSI(finalByte: byte, latestDirective: &latestDirective)
        case 0x00...0x1F, 0x7F:
            break
        default:
            state = .ground
        }
    }

    private mutating func appendCSIDigit(_ digit: Int) {
        switch csiParameter {
        case .omitted:
            csiParameter = .value(digit)
        case .value(let value):
            // Seven is sufficient to represent every unsupported value and
            // avoids integer overflow for attacker-controlled digit runs.
            csiParameter = .value(min(7, value * 10 + digit))
        case .invalid:
            break
        }
    }

    private mutating func consumeCSIIntermediateByte(
        _ byte: UInt8,
        latestDirective: inout Directive?
    ) {
        switch byte {
        case 0x20...0x2F:
            csiHasSingleSpaceIntermediate = false
        case 0x30...0x3F:
            state = .csiIgnore
        case 0x40...0x7E:
            finishCSI(finalByte: byte, latestDirective: &latestDirective)
        case 0x00...0x1F, 0x7F:
            break
        default:
            state = .ground
        }
    }

    private mutating func consumeCSIIgnoreByte(_ byte: UInt8) {
        switch byte {
        case 0x40...0x7E:
            state = .ground
        case 0x00...0x3F, 0x7F:
            break
        default:
            state = .ground
        }
    }

    private mutating func finishCSI(
        finalByte: UInt8,
        latestDirective: inout Directive?
    ) {
        defer { state = .ground }
        guard finalByte == 0x71, // q
              csiHasSingleSpaceIntermediate else { return }

        switch csiParameter {
        case .omitted, .value(0):
            latestDirective = .preferred
        case .value(let parameter) where (1...6).contains(parameter):
            latestDirective = .explicit(parameter: parameter)
        case .value, .invalid:
            break
        }
    }

    private mutating func consumeControlStringByte(
        _ byte: UInt8,
        allowsBellTermination: Bool
    ) {
        switch byte {
        case 0x9C, 0x18, 0x1A: // C1 ST, CAN, SUB
            state = .ground
        case 0x07 where allowsBellTermination: // OSC BEL terminator
            state = .ground
        case 0x1B:
            state = .controlStringEscape(
                allowsBellTermination: allowsBellTermination
            )
        default:
            break
        }
    }

    private mutating func consumeControlStringEscapeByte(
        _ byte: UInt8,
        allowsBellTermination: Bool
    ) {
        switch byte {
        case 0x5C, 0x9C, 0x18, 0x1A: // ESC \\ / C1 ST / CAN / SUB
            state = .ground
        case 0x07 where allowsBellTermination:
            state = .ground
        case 0x1B:
            break
        default:
            // A non-ST byte remains payload. In particular, an ESC-[ pair
            // inside OSC/DCS must never be reinterpreted as CSI.
            state = .controlString(
                allowsBellTermination: allowsBellTermination
            )
        }
    }
}
