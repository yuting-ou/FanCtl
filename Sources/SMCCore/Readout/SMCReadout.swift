import Foundation
import IOKit
import SMCCore   // 共享层：SMCError / SMCValue / SMCIORead / fourCC 系列

// MARK: - AppleSMC 只读通路（target: SMCReadout）
//
// 这个模块**不存在写原语**：没有 writeKey 命令码、没有 write/writeDouble，
// raw `call` 与 `keyInfo` 都是文件私有。fanprobe 用它读传感器与风扇状态，
// 即便有人往 fanprobe 里加代码，也拿不到 SMCCore 的 SMCIO 写面实现。
//
// 下面 80 字节参数结构体与 Driver/SMCDriver.swift 各存一份，是刻意的能力隔离代价
// （见那边的注释）。两处布局由 `// SMCParamStruct layout:` 标记，改一处必改两处。

// SMCParamStruct layout: v1 —— 与 Driver 侧同布局，80 字节
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

// 只读命令码：故意不声明 writeKey = 6，写命令在本模块中不存在
private enum SMCReadCommand: UInt8 {
    case readKey = 5
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

private let kSMCUserClientSelector: UInt32 = 2  // kSMCHandleYPCEvent
private let kSMCResultKeyNotFound: UInt8 = 132

/// 只读 SMC 连接：实现 SMCCore 的 SMCIORead，不实现 SMCIO。
public final class SMCReadConnection: SMCIORead {
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
        // 与 Driver 侧同因：并发 IOConnectCallStructMethod 未定义，用锁串行化。
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
        input.data8 = SMCReadCommand.getKeyInfo.rawValue
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
        input.data8 = SMCReadCommand.readKey.rawValue
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

    public func allKeys() throws -> [String] {
        // 防御 NaN/Inf/超大值导致 Int() trap（同 Driver 侧 allKeys 的守卫）
        let raw = try readDouble("#KEY")
        let count = raw.isFinite && raw > 0 ? Int(min(raw, 10000)) : 0
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var input = SMCParamStruct()
            input.data8 = SMCReadCommand.getKeyFromIndex.rawValue
            input.data32 = UInt32(i)
            guard let output = try? call(&input), output.result == 0 else { continue }
            keys.append(fourCCToString(output.key))
        }
        return keys
    }
}
