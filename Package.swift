// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanCtl",
    platforms: [.macOS("26.0")],
    targets: [
        // SMC 共享层：值类型/协议面、配置模型、控制策略与引擎——**不含 IOKit，不含写实现**
        // Driver/ 与 Readout/ 是独立 target 的源码目录，故从本 target 排除。
        .target(name: "SMCCore", exclude: ["Driver", "Readout"]),
        // SMC 写驱动（IOKit 读写全能力 + FanController 写实现）。
        // 安全边界：只有 root 守护进程 fanctld（与逻辑测试）依赖它——
        // FanCtlApp 与 fanprobe 的依赖图里不存在本 target，因此它们连"写"这个 API 都拿不到。
        .target(name: "SMCDriver", dependencies: ["SMCCore"], path: "Sources/SMCCore/Driver"),
        // SMC 只读通路（整个模块无写原语），供 fanprobe 读传感器/风扇状态。
        .target(name: "SMCReadout", dependencies: ["SMCCore"], path: "Sources/SMCCore/Readout"),
        // 后台守护进程（root 运行）：按温度曲线自动调速
        .executableTarget(name: "fanctld", dependencies: ["SMCCore", "SMCDriver"]),
        // 菜单栏 App：只读 status.json，无硬件通路
        .executableTarget(name: "FanCtlApp", dependencies: ["SMCCore"]),
        // 只读诊断工具
        .executableTarget(name: "fanprobe", dependencies: ["SMCCore", "SMCReadout"]),
        // MCP 服务器（stdio）：把 status/config 暴露给本地 AI 客户端（协议核心在 SMCCore.FanMCP）
        .executableTarget(name: "fanmcp", dependencies: ["SMCCore"]),
        // 纯逻辑测试（自带轻量断言 harness，无需 Xcode/XCTest，swift run fanctltests）
        // Fixtures/ 用 #filePath 定位（v3.4 E 项），不走 SwiftPM 资源机制——exclude 消音
        .executableTarget(name: "fanctltests", dependencies: ["SMCCore", "SMCDriver"],
                          exclude: ["Fixtures"]),
    ]
)
