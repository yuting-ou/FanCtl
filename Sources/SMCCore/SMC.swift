import Foundation

// MARK: - AppleSMC 值类型与访问协议（本文件不含 IOKit，也不含任何写实现）
//
// 安全边界（本轮加固）：与 AppleSMC 内核驱动对话的 IOKit 通路按能力拆成两个 target，
// 二者都依赖本模块，但本模块看不到它们：
//   SMCCore/Driver/   → target `SMCDriver`：读写连接 + FanController 的写实现。
//                       只有守护进程 fanctld（root）与 fanctltests 依赖它。
//   SMCCore/Readout/  → target `SMCReadout`：只读连接，整个模块不存在写原语。
//                       fanprobe 用它读硬件；FanCtlApp 连它都不依赖（App 只读 status.json）。
// 于是"能不能写 SMC"由 SwiftPM 依赖图决定，而不是靠"当前没有调用"的自觉。
// 协议面 = 现有公开操作全集，不额外承诺能力；测试侧 MockSMC 仍实现 SMCIO。

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
// 读面单独成协议：只读通路（SMCReadout）实现它即可，不需要、也拿不到写面。
public protocol SMCIORead {
    func read(_ key: String) throws -> SMCValue
    func readDouble(_ key: String) throws -> Double
    func keyExists(_ key: String) -> Bool
    func allKeys() throws -> [String]
}

/// 协议面 = 现有公开操作全集，不额外承诺能力。
public protocol SMCIO: SMCIORead {
    func write(_ key: String, bytes: [UInt8]) throws
    func writeDouble(_ key: String, value: Double) throws
}
