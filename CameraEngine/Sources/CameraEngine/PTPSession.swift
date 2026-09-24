import Foundation
import CPTPTransport

public enum PTPOp {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let getDevicePropDesc: UInt16 = 0x1014
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016
    public static let terminateOpenCapture: UInt16 = 0x1018
    public static let initiateOpenCapture: UInt16 = 0x101C
}

public enum PTPRC {
    public static let ok: UInt16 = 0x2001
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let accessDenied: UInt16 = 0x200F
    public static let deviceBusy: UInt16 = 0x2019
    public static let sessionAlreadyOpen: UInt16 = 0x201E
}

public enum PTPSessionError: Error {
    case shortRead
    case unexpectedContainer(UInt16)
    case malformedResponse
}

public struct PTPCommandResult {
    public let responseCode: UInt16
    public let responseParams: [UInt32]
    public let data: Data?
}

public final class PTPSession {
    private let transport: PTPUSBTransport
    private var transactionID: UInt32 = 0
    private let readTimeout: TimeInterval = 5
    /// How many stale containers to discard before giving up on resynchronising.
    private let maxStaleContainers = 8

    public init(transport: PTPUSBTransport) {
        self.transport = transport
    }

    public func open(sessionID: UInt32 = 1) throws -> UInt16 {
        var rc = try bareCommand(code: PTPOp.openSession, params: [sessionID])
        if rc == PTPRC.sessionAlreadyOpen {
            _ = try bareCommand(code: PTPOp.closeSession, params: [])
            rc = try bareCommand(code: PTPOp.openSession, params: [sessionID])
        }
        transactionID = 0
        return rc
    }

    public func close() throws -> UInt16 {
        try bareCommand(code: PTPOp.closeSession, params: [])
    }

    private func bareCommand(code: UInt16, params: [UInt32]) throws -> UInt16 {
        let cmd = PTP.container(type: .command, code: code, transactionID: 0, params: params)
        try write(cmd)
        let response = try read()
        guard response.count >= PTP.headerLength else { throw PTPSessionError.shortRead }
        return response.readLE(at: 6)
    }

    /// - Parameter timeout: overrides the default read timeout for this call only.
    public func command(code: UInt16, params: [UInt32] = [], dataOut: Data? = nil,
                        timeout: TimeInterval? = nil) throws -> PTPCommandResult {
        transactionID += 1
        let cmd = PTP.container(type: .command, code: code, transactionID: transactionID, params: params)
        try write(cmd)

        if let dataOut {
            let dataContainer = PTP.container(type: .data, code: code, transactionID: transactionID, payload: dataOut)
            try write(dataContainer)
        }

        var first = try readContainer(timeout)
        guard let header = PTPContainerHeader(first) else {
            throw PTPSessionError.malformedResponse
        }

        var dataIn: Data? = nil
        if header.type == .data {
            let declared = Int(header.length)
            var acc = first
            while acc.count < declared {
                let more = try read(timeout)
                if more.isEmpty { break }
                acc.append(more)
            }
            let dataEnd = min(acc.count, declared)
            dataIn = dataEnd > PTP.headerLength ? acc.subdata(in: (acc.startIndex + PTP.headerLength)..<(acc.startIndex + dataEnd)) : Data()
            if acc.count > declared {
                first = acc.subdata(in: (acc.startIndex + declared)..<acc.endIndex)
            } else {
                first = try readContainer(timeout)
            }
        }

        guard let response = PTPResponse(first) else {
            if let h = PTPContainerHeader(first) { throw PTPSessionError.unexpectedContainer(h.type.rawValue) }
            throw PTPSessionError.malformedResponse
        }
        return PTPCommandResult(responseCode: response.code, responseParams: response.params, data: dataIn)
    }

    public func deviceInfo() throws -> PTPDeviceInfo? {
        let result = try command(code: PTPOp.getDeviceInfo)
        guard result.responseCode == PTPRC.ok, let data = result.data else { return nil }
        return PTPDeviceInfo(data)
    }

    public func propertyDescription(_ property: UInt16) throws -> (rc: UInt16, desc: PTPPropDesc?) {
        let result = try command(code: PTPOp.getDevicePropDesc, params: [UInt32(property)])
        guard result.responseCode == PTPRC.ok, let data = result.data else {
            return (result.responseCode, nil)
        }
        return (result.responseCode, PTPPropDesc(data))
    }

    public func getPropU16(_ property: UInt16) throws -> (rc: UInt16, value: UInt16?) {
        let result = try command(code: PTPOp.getDevicePropValue, params: [UInt32(property)])
        guard result.responseCode == PTPRC.ok, let data = result.data, data.count >= 2 else {
            return (result.responseCode, nil)
        }
        return (result.responseCode, data.readLE(at: 0))
    }

    public func setPropU16(_ property: UInt16, _ value: UInt16,
                           timeout: TimeInterval? = nil) throws -> UInt16 {
        var payload = Data()
        payload.appendLE(value)
        return try setProp(property, payload: payload, timeout: timeout)
    }

    public func setProp(_ property: UInt16, payload: Data,
                        timeout: TimeInterval? = nil) throws -> UInt16 {
        let result = try command(code: PTPOp.setDevicePropValue, params: [UInt32(property)],
                                 dataOut: payload, timeout: timeout)
        return result.responseCode
    }

    private func write(_ data: Data) throws {
        try transport.write(data)
    }

    private func read(_ timeout: TimeInterval? = nil) throws -> Data {
        try transport.read(withTimeout: timeout ?? readTimeout)
    }

    /// Reads the next container that belongs to the current transaction.
    ///
    /// A command whose read timed out can still have its response delivered
    /// afterwards. If that late container is taken as the answer to the *next*
    /// command, every transaction from then on is off by one and the session never
    /// recovers - the camera appears to hang and only a battery pull clears it.
    /// PTP stamps every container with the transaction it belongs to, so a stale
    /// one can simply be dropped and the next read tried instead.
    private func readContainer(_ timeout: TimeInterval?) throws -> Data {
        for _ in 0..<maxStaleContainers {
            let data = try read(timeout)
            guard let header = PTPContainerHeader(data) else { return data }
            if header.transactionID == transactionID || header.transactionID == 0 {
                return data
            }
            EngineLog.add(String(format: "discarded stale container for transaction %u (current %u)",
                                 header.transactionID, transactionID))
        }
        throw PTPSessionError.malformedResponse
    }

    /// Absorbs a response that arrived after its command timed out.
    ///
    /// Without this the stale container is picked up by the *next* command and
    /// every transaction from then on is misaligned, which on some bodies wedges
    /// the PTP function until the camera is power cycled.
    public func drain(timeout: TimeInterval) {
        while let data = try? transport.read(withTimeout: timeout), !data.isEmpty {
            continue
        }
    }
}
