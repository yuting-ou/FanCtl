// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanCtl",
    platforms: [.macOS("26.0")],
    targets: [
        // SMC 访问核心库：温度传感器读取、风扇控制、配置模型
        .target(name: "SMCCore"),
        // 后台守护进程（root 运行）：按温度曲线自动调速
        .executableTarget(name: "fanctld", dependencies: ["SMCCore"]),
        // 菜单栏 App
        .executableTarget(name: "FanCtlApp", dependencies: ["SMCCore"]),
        // 只读诊断工具
        .executableTarget(name: "fanprobe", dependencies: ["SMCCore"]),
        // 纯逻辑测试（自带轻量断言 harness，无需 Xcode/XCTest，swift run fanctltests）
        .executableTarget(name: "fanctltests", dependencies: ["SMCCore"]),
    ]
)
