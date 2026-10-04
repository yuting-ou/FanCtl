import Foundation
import IOKit
import SMCCore   // 共享层：SMCError / SMCValue / SMCIO / FanReadout / FanState

// MARK: - AppleSMC IOKit 通信层（读写全能力，target: SMCDriver）
// 通过 IOConnectCallStructMethod 与 AppleSMC 内核驱动交换 80 字节参数结构体。
// 读取无需特权，写入（风扇控制）需要 root。
//
// 本文件里的 80 字节结构体布局与 SMCReadout/SMCReadConnection.swift 各存一份，是**刻意的**：
// 只读通路必须连 `writeKey` 命令码和 raw call 都拿不到，否则"不能写"就退化成了
// "没有语义 API"而非"没有能力"。两处布局由 `// SMCParamStruct layout:` 标记，改一处必改两处。

// SMCParamStruct layout: v1 —— 与 Readout 侧同布局，80 字节
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

// MARK: - SMC 连接（读写）

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

// MARK: - 风扇写实现（从 SMCCore 迁入）

/// 只有依赖本 target 的程序（fanctld / fanctltests）能构造出它，
/// 因此"写风扇转速"这件事在依赖图层面就只属于 root 守护进程。
public final class FanController: FanReadout, FanActuating {
    /// 写面句柄：与基类的只读句柄指向同一连接，但只在这里以 SMCIO 形式持有。
    private let w: SMCIO

    /// 保持与拆分前完全相同的调用形态 `FanController(smc:)`——fanctld 与既有测试的
    /// 构造点一行都不用改（断言不许动）；能力差异靠"谁能 import 到本 target"体现。
    public init(smc: SMCIO) throws {
        self.w = smc
        try super.init(smc: smc)
    }

    // 强制指定转速（需要 root）
    public func setForcedRPM(fan: Int, rpm: Double) throws {
        try setForcedRPM(state: try state(of: fan), rpm: rpm)
    }

    // 用已读取的 FanState 写入目标转速（不再重读 SMC，给主循环复用）
    public func setForcedRPM(state st: FanState, rpm: Double) throws {
        // 防御：min/max 无效（读失败返回 0）时禁止写入——否则任意百分比映射为 0，
        // 会把 92°C 兜底的 100% 也写成 Tg=0（风扇停转），安全红线被静默击穿。
        // 调用方（daemon 写入循环）捕获此错误后走 writeHealth 故障路径。
        guard st.maxRPM > st.minRPM, st.maxRPM > 0, st.minRPM >= 0 else {
            throw SMCError.smcResult("F\(st.id)Mx", 0xFD)
        }
        let clamped = max(st.minRPM, min(st.maxRPM, rpm))
        if hasModeKey {
            try w.writeDouble("F\(st.id)Md", value: 1)
            try w.writeDouble("F\(st.id)Tg", value: clamped)
        } else {
            // Intel: 置 FS! 对应位后写 F{n}Tg
            // 读取失败时不能默认 0，否则会清除其他风扇的强制位
            // v3.6.1：id ≥ 16 时 1 << id 溢出 UInt16——强制位静默写丢（set）或
            // UInt16(65536) runtime trap（restore，root 崩溃循环）。SMC FS! 只有 16 位
            guard st.id < 16 else {
                throw SMCError.smcResult("FS! ", 0xFE)
            }
            guard let raw = try? w.readDouble("FS! ") else {
                throw SMCError.keyNotFound("FS! ")
            }
            // 防御：SMC 损坏/异常固件可能返回负值或 ≥65536，UInt16() 对越界值
            // precondition trap 会使 root daemon 崩溃（其余 SMC 数值路径都有显式钳位）
            let mask = raw.isFinite ? max(0, min(65535, raw)) : 0
            try w.writeDouble("FS! ", value: Double(UInt16(mask) | (1 << st.id)))
            try w.writeDouble("F\(st.id)Tg", value: clamped)
        }
    }

    // 交还系统自动调度（需要 root）
    public func restoreAuto(fan: Int) throws {
        if hasModeKey {
            try w.writeDouble("F\(fan)Md", value: 0)
        } else {
            // v3.6.1：同 setForcedRPM——fan ≥ 16 时 UInt16(1 << fan) runtime trap
            guard fan < 16 else {
                throw SMCError.smcResult("FS! ", 0xFE)
            }
            guard let raw = try? w.readDouble("FS! ") else {
                throw SMCError.keyNotFound("FS! ")
            }
            let mask = raw.isFinite ? max(0, min(65535, raw)) : 0
            try w.writeDouble("FS! ", value: Double(UInt16(mask) & ~UInt16(1 << fan)))
        }
    }

    public func restoreAutoAll() {
        for i in 0..<fanCount {
            try? restoreAuto(fan: i)
        }
    }

    // 批量设置所有风扇的强制百分比（支持独立偏移后每个风扇百分比不同）
    // percents 数组按风扇索引对应，数量不足时用第一个值填充
    public func setForcedPercentsAll(_ percents: [Double], states: [FanState]) throws {
        for (i, st) in states.enumerated() {
            let pct = i < percents.count ? percents[i] : (percents.first ?? 50)
            let rpm = self.rpm(forPercent: pct, state: st)
            try setForcedRPM(state: st, rpm: rpm)
        }
    }
}
