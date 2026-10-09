// fanmcp —— 清风的 MCP stdio 入口
//
// 协议核心在 SMCCore.FanMCP（可全量单测），本文件只做 IO 壳层：
// stdin 逐行读 JSON-RPC → FanMCP.handle → stdout 写回（紧凑单行）。
// **stdout 是协议通道**：任何日志/打印都只许走 stderr，否则一行杂音就炸协议。
//
// 生命周期：stdin EOF（客户端关闭）→ 正常退出；SIGTERM/SIGINT 用默认处理——
// 本进程从不碰 SMC，唯一在途操作是 config.json 的原子写（O_EXCL + rename，
// 最坏留旧文件），无需清理例程。Hermes 等客户端按需拉起、随会话结束回收。

import Foundation
import SMCCore

// 与 VERSION 同步（fanctltests 有同源门钉住，改 VERSION 必须同步这里）
let fanmcpVersion = "4.2.52 (146)"

let server = FanMCP.live(version: fanmcpVersion)
let stderr = FileHandle.standardError
func logErr(_ s: String) {
    stderr.write(Data((s + "\n").utf8))
}

logErr("fanmcp \(fanmcpVersion) ready（stdio · 8 tools · 清风 MCP）")

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var buffer = Data()
let maxBufferBytes = 4 * 1024 * 1024   // 单行护栏：MCP 消息远小于此，防异常输入无限吃内存

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }   // EOF：客户端关闭会话 → 正常退出
    buffer.append(chunk)
    if buffer.count > maxBufferBytes {
        logErr("fanmcp: 输入超过 \(maxBufferBytes) 字节仍无换行，丢弃缓冲（异常客户端？）")
        buffer.removeAll(keepingCapacity: false)
        continue
    }
    while let nl = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.prefix(upTo: nl)
        buffer = buffer.suffix(from: buffer.index(after: nl))
        if let response = server.handle(String(data: lineData, encoding: .utf8) ?? "") {
            output.write(response)
            output.write(Data("\n".utf8))
        }
    }
}
logErr("fanmcp: stdin EOF，正常退出")
exit(0)
