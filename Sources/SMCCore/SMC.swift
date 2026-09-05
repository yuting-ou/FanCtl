import Foundation
import IOKit

// MARK: - AppleSMC IOKit 通信层
// 通过 IOConnectCallStructMethod 与 AppleSMC 内核驱动交换 80 字节参数结构体。
// 读取无需特权，写入（风扇控制）需要 root。

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcResult(String, UInt8)
    case notPrivileged

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed: \(kr)"
        case .callFailed(let kr): return "IOConnectCallStructMethod failed: \(kr)"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .smcResult(let key, let r): return "SMC error for key \(key): result=\(r)"
        case .notPrivileged: return "SMC write requires root privileges"
        }
    }
}

// 与 AppleSMC 驱动约定的参数结构体，布局必须精确为 80 字节
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// SMC 命令码
private enum SMCCommand: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

private let kSMCUserClientSelector: UInt32 = 2  // kSMCHandleYPCEvent
private let kSMCResultKeyNotFound: UInt8 = 132

// MARK: - 键值编码

public func fourCC(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for c in s.utf8.prefix(4) {
        result = (result << 8) | UInt32(c)
    }
    return result
}

public func fourCCToString(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

// MARK: - SMC 数据值

public struct SMCValue {
    public let key: String
    public let dataType: String  // "flt ", "ui8 ", "fpe2", "sp78" ...
    public let dataSize: Int
    public let bytes: [UInt8]

    // 显式 public init：合成的 memberwise 是 internal，测试侧 MockSMC 需要构造假读数
    public init(key: String, dataType: String, dataSize: Int, bytes: [UInt8]) {
        self.key = key
        self.dataType = dataType
        self.dataSize = dataSize
        self.bytes = bytes
    }

    // 按类型解码为 Double
    public var doubleValue: Double? {
        switch dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // Apple Silicon 上 flt 为原生小端 IEEE754
            let v = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float32.self) }
            return Double(v)
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ", "ui16", "ui32", "ui64":
            // SMC 整型约定为大端
            var v: UInt64 = 0
            for b in bytes.prefix(dataSize) { v = (v << 8) | UInt64(b) }
            return Double(v)
        case "si8 ", "si16":
            // v3.6.1：有符号类型按位型解码——此前并入无符号分支，负值变巨正值
            var v: UInt64 = 0
            for b in bytes.prefix(dataSize) { v = (v << 8) | UInt64(b) }
            switch dataSize {
            case 1: return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: v)))
            default: return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: v)))
            }
        default:
            return nil
        }
    }
}

// MARK: - SMC 访问抽象

// FanController/TemperatureSensors 只依赖此协议而非具体连接：
// 测试可注入 MockSMC 验证控制编排（模式切换写入/传感器筛选/钳位），无需真实硬件。
// 协议面 = 现有公开操作全集，不额外承诺能力。
public protocol SMCIO {
    func read(_ key: String) throws -> SMCValue
    func readDouble(_ key: String) throws -> Double
    func write(_ key: String, bytes: [UInt8]) throws
    func writeDouble(_ key: String, value: Double) throws
    func keyExists(_ key: String) -> Bool
    func allKeys() throws -> [String]
}

// MARK: - SMC 连接

public final class SMCConnection: SMCIO {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        // v3.6.1：重扫后台队列（rescanQueue）与主队列控制拍共用同一 io_connect_t，
        // IOConnectCallStructMethod 并发调用未定义（main.swift 看门狗注释自述"call 无锁
        // 并发未定义"）。用既有 lock 串行化全部调用；keyInfo 的缓存段与 call 不嵌套，无死锁。
        // 代价：全量重扫期间主拍读数最多等待单次 SMC 调用时长（亚毫秒级），可忽略。
        lock.lock()
        defer { lock.unlock() }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection,
                                           kSMCUserClientSelector,
                                           &input,
                                           MemoryLayout<SMCParamStruct>.stride,
                                           &output,
                                           &outputSize)
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        return output
    }

    private func keyInfo(_ keyCode: UInt32) throws -> SMCKeyInfoData {
        lock.lock()
        if let cached = keyInfoCache[keyCode] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = SMCCommand.getKeyInfo.rawValue
        let output = try call(&input)
        if output.result == kSMCResultKeyNotFound {
            throw SMCError.keyNotFound(fourCCToString(keyCode))
        }
        guard output.result == 0 else {
            throw SMCError.smcResult(fourCCToString(keyCode), output.result)
        }
        lock.lock()
        keyInfoCache[keyCode] = output.keyInfo
        lock.unlock()
        return output.keyInfo
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(fourCC(key))) != nil
    }

    public func read(_ key: String) throws -> SMCValue {
        let keyCode = fourCC(key)
        let info = try keyInfo(keyCode)

        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCommand.readKey.rawValue
        let output = try call(&input)
        if output.result == kSMCResultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }

        let size = Int(info.dataSize)
        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<min(size, 32) { bytes[i] = raw[i] }
        }
        return SMCValue(key: key,
                        dataType: fourCCToString(info.dataType),
                        dataSize: size,
                        bytes: Array(bytes.prefix(size)))
    }

    public func readDouble(_ key: String) throws -> Double {
        guard let v = try read(key).doubleValue else {
            throw SMCError.smcResult(key, 0xFF)
        }
        return v
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let keyCode = fourCC(key)
        let info = try keyInfo(keyCode)

        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCommand.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<min(bytes.count, 32) { raw[i] = bytes[i] }
        }
        let output = try call(&input)
        if output.result == kSMCResultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }
    }

    // 按目标键的实际类型编码写入数值
    public func writeDouble(_ key: String, value: Double) throws {
        let info = try keyInfo(fourCC(key))
        let type = fourCCToString(info.dataType)
        switch type {
        case "flt ":
            var f = Float32(value)
            var bytes = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: &f) { raw in
                for i in 0..<4 { bytes[i] = raw[i] }
            }
            try write(key, bytes: bytes)
        case "fpe2":
            let raw = UInt16(max(0, min(65535, value * 4)))
            try write(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
        case "ui8 ":
            try write(key, bytes: [UInt8(max(0, min(255, value)))])
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            try write(key, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
        default:
            throw SMCError.smcResult(key, 0xFE)
        }
    }

    // 枚举全部 SMC 键（用于传感器发现）
    public func allKeys() throws -> [String] {
        // 防御 NaN/Inf/超大值导致 Int() trap（同 FanController.init 的 fnum 守卫）
        let raw = try readDouble("#KEY")
        let count = raw.isFinite && raw > 0 ? Int(min(raw, 10000)) : 0
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var input = SMCParamStruct()
            input.data8 = SMCCommand.getKeyFromIndex.rawValue
            input.data32 = UInt32(i)
            guard let output = try? call(&input), output.result == 0 else { continue }
            keys.append(fourCCToString(output.key))
        }
        return keys
    }
}
