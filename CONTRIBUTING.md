# 贡献指南

感谢你愿意为 FanCtl（清风）贡献代码！这是一个运行在 root 权限下、直接控制 SMC 风扇的 macOS 工具——**改动前请务必先读下面的安全与质量要求**。

## 开发环境

- macOS 26+（Apple Silicon / Intel 均可）
- Swift 5.9+（无需 Xcode，SwiftPM 即可）
- 无第三方依赖

## 本地验证

```bash
# 回归测试（~2415 断言，失败退出码非 0）
swift run -c release --disable-sandbox fanctltests

# Release 构建
swift build -c release --disable-sandbox

# 完整构建（先测试再组装 dist/）
./scripts/build.sh
```

提交 PR 前必须通过本地回归测试；CI 也会自动跑同一套测试。

## 代码规范

项目有明确的核心模块约定，**修改逻辑前请先读对应文件头注释**（内含物理依据与踩坑史）。务必遵守：

1. **安全红线不可让**：92°C 高温兜底 / SSD 78°C 危急 / 传感器故障交还系统，任何新功能不得压低或绕过。静音/夜间/电池档都只是"红线之上的覆盖"。
2. **向后兼容是硬约束**：所有 JSON（config/status/stats/learn）都有自定义 Codable 处理旧数据缺字段；新增非 Optional 字段必须 `decodeIfPresent` + 默认值。
3. **App 不得直连 SMC**：App 展示一律读 status.json（daemon 决策），不得在 App 侧重算控制语义。
4. **防御 NaN/Inf**：传感器读数和外部 JSON 都可能携带坏值；Double→Int 转换必须钳位（isFinite 检查）。
5. **时间语义**：自适应循环间隔 1~20s，所有"每拍"参数按 3s 标称拍标定；按秒的计时用秒。
6. **fd 生命周期**：文件监控（DispatchSource）重建时 fd 只由 cancelHandler 关闭，严禁 eager close 后 open。
7. **改动 SMCCore 后必须跑 fanctltests**：测试与 daemon 共用同一份决策代码，防止镜像漂移。

## 提交 PR

1. Fork 本仓库并创建功能分支
2. 保持提交信息简洁清晰（可参考历史提交风格）
3. 跑通本地回归测试 + 构建
4. 发起 PR，说明改动动机与验证方式
5. 参与 review 讨论，直到合并

## 测试基建提示

`fanctltests` 里的 `VirtualMachine` 是一阶热模型，可闭环验证控制器（防极限环/过冲）。新增控制参数建议先用它仿真再上真机。

有任何疑问，直接在 Issue 或 PR 中提出即可。
