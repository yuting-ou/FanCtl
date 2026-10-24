// PanelModes —— 调速卡的四个模式内容与 AI 卡共享构建件（R89 自 PanelView 拆出，
// 零视觉搬移）。四个模式内容由 controlCard（PanelView）按 model.mode 分派；
// statStrip/adaptiveChip/curveAIComboBar/intentStyle/learningStatus 只被本文件引用，
// 保持 private。依赖 PanelControls/PanelEffects/PanelCards 的跨文件组件均为 internal。
import SwiftUI
import SMCCore
import FanCtlAppCore

extension ContentView {
    var curveContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSegmentedPicker(items: CurvePreset.allCases.map { ($0.displayName, $0) },
                                 selection: Binding(get: { model.preset }, set: { model.setPreset($0) }))

            // 自定义档：可拖动控制点；其余预设只读展示。
            // 电池档/夜间档覆盖生效时画对应档位曲线，否则橘色输出点会脱离曲线悬空。
            // AI 建议块在场时图表高度 92→52：基础内容 ≈155pt + 建议块 ≈80pt 超过
            // 200pt 槽位，底部的"确认应用/保留当前"按钮会被裁剪点不到（与历史
            // "面板点不动"bug 同类）；压缩图表给建议块让位，确认后自动恢复 92pt
            if model.preset == .custom && !model.batteryOverride && !model.nightOverride {
                EditableCurveChart(points: model.customPoints,
                                   currentTemp: max(model.cpuTemp, model.gpuTemp),
                                   appliedPercent: model.appliedPercent,
                                   live: model.daemonAlive,
                                   onChange: { model.updateCustomPoints($0) },
                                   height: model.pendingAICurve != nil ? 52 : 92)
                // #13: 恢复到均衡预设（自定义模式的初始基准）
                if snapshotPlainCards {
                    // 快照：borderless Button 离屏退 🚫 → 静态 Label（自定义档这一屏要量排版）
                    Label("恢复预设", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                Button {
                    model.updateCustomPoints(CurvePreset.balanced.points)
                } label: {
                    Label("恢复预设", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                }
            } else {
                CurveChart(config: model.batteryOverride
                               ? FanConfig(mode: .curve, curve: model.points(for: .quiet), preset: .quiet)
                               : (model.nightOverride
                                  ? FanConfig(mode: .curve, curve: model.points(for: .quiet), preset: .quiet)
                                  : model.config),
                           currentTemp: max(model.cpuTemp, model.gpuTemp),
                           appliedPercent: model.appliedPercent,
                           live: model.daemonAlive,
                           height: model.pendingAICurve != nil ? 52 : 92)
            }
            
            // 底部提示行：电池覆盖 > AI 结论 > 再优化提示 > 常规；右侧 AI 优化按钮
            HStack(spacing: 6) {
                Text(batteryHint ?? nightHint ?? model.aiSummary
                     ?? (model.aiNudge ? "💡 数据已更新，建议重新 AI 优化" : nil)
                     ?? (model.preset == .custom
                                     ? "拖动蓝色控制点自定义曲线 · 当前输出 \(Int(model.appliedPercent))%"
                                     : model.aiPresetCurves.isEmpty
                                     ? "当前输出 \(Int(model.appliedPercent))% · 高温 92°C 自动全速兜底"
                                     : "预设已 AI 个性化 · 当前输出 \(Int(model.appliedPercent))% · 92° 兜底"))
                    .font(.caption2)
                    .foregroundStyle(model.batteryOverride ? AnyShapeStyle(.orange)
                                     : model.aiSummary != nil ? AnyShapeStyle(.purple)
                                     : model.aiNudge ? AnyShapeStyle(.purple)
                                     : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.aiDetail ?? "")
                Spacer(minLength: 4)
                if snapshotPlainCards {
                    // 快照：borderless Button 桥接 AppKit 离屏退 🚫 → 等尺寸静态标签
                    Label("AI 优化", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                } else {
                    Button {
                        model.applyAICurve()
                    } label: {
                        Label("AI 优化", systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.purple)
                    .help("分析这台机器的历史温度分布，自动生成专属风扇曲线（纯本地分析，不联网）")
                }
            }
            // 控制点摘要：统一数据条（温度为主值、风量为副值），与 AI 评测条同语言。
            // 建议块在场时让位（200pt 槽位）。
            if model.pendingAICurve == nil {
                statStrip(displayedCurvePoints.map { p in
                    ("\(Int(p.temp))°", "\(Int(p.percent))% 风量", nil)
                })
            }
            if let suggestion = model.pendingAICurve {
                VStack(alignment: .leading, spacing: 6) {
                    Label("新的 AI 曲线建议", systemImage: "sparkles")
                        .font(.caption.weight(.semibold)).foregroundStyle(.purple)
                    Text(suggestion.summary)
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        if snapshotPlainCards {
                            // 快照：borderless Button 桥接 AppKit 离屏退 🚫 → 等尺寸静态标签
                            //（这一屏要量动作行的排版，占位块会把整行盖掉）
                            Text("保留当前")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("保留当前") { model.dismissAICurve() }
                                .buttonStyle(.borderless)
                        }
                        Spacer()
                        Button("确认应用") { model.confirmAICurve() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.purple)
                    }
                }
                .padding(8)
                .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    
    // 曲线卡当前实际展示的锚点（与 CurveChart/EditableCurveChart 数据源一致）
    private var displayedCurvePoints: [CurvePoint] {
        if model.preset == .custom && !model.batteryOverride && !model.nightOverride {
            return model.customPoints
        }
        if model.batteryOverride || model.nightOverride {
            return model.points(for: .quiet)
        }
        return model.config.curve
    }

    // 电源感知覆盖时给用户一个明确提示，避免“曲线和实际输出对不上”的困惑
    private var batteryHint: String? {
        model.batteryOverride
            ? "电池供电 · 安静档生效中 · 当前输出 \(Int(model.appliedPercent))%"
            : nil
    }

    // 夜间覆盖同理：此时卡上画的是安静档曲线、自定义档的控制点**不在屏上**，
    // 不能再提示"拖动蓝色控制点"（4.2.55 逐屏量时踩到：夜间档生效 + 自定义档同屏时，
    // 旧文案指向一个画面上不存在的操作）。句式与长度对齐 batteryHint——提示行右侧还有
    // "AI 优化"按钮，超过 ~20 字会被 tail 截断（第一版 26 字实测截成"当前…"）。
    private var nightHint: String? {
        model.nightOverride
            ? "夜间安静档生效中 · 当前输出 \(Int(model.appliedPercent))%"
            : nil
    }

    var manualContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 内容在 200pt 固定框内垂直居中，避免顶部拥挤、底部大段留白导致的失衡感
            Spacer(minLength: 0)
            // 大号百分比显示，控制中心风格
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(model.manualPercent))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.manualPercent)
                Text("%")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.fans.count == 2 {
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(model.fans, id: \.id) { fan in
                            Text("\(fan.id == 0 ? "左" : "右") \(Int(fan.targetRPM)) RPM")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "fanblades")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if snapshotPlainCards {
                    // 快照：Slider 桥接 AppKit 离屏退 🚫 → 等尺寸静态轨道
                    GeometryReader { geo in
                        let pct = CGFloat(min(max(model.manualPercent, 0), 100) / 100)
                        let x = geo.size.width * pct
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .indigo],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: x, height: 4)
                            Circle().fill(.white).frame(width: 14, height: 14)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                                .offset(x: min(max(x - 7, 0), geo.size.width - 14))
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 20)
                } else {
                    Slider(value: Binding(
                        get: { model.manualPercent },
                        set: { model.setManualPercent($0) }
                    ), in: 0...100, step: 5)
                    .tint(LinearGradient(colors: [.blue, .indigo],
                                         startPoint: .leading, endPoint: .trailing))
                }
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            Text("0% = 最低转速 · 100% = 全速 · 高温 92°C 自动全速兜底")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 快捷档位：拖动之外给一键落点，同时填满 200pt 槽位底部留白。
            // 真 Button（AXPress 可达）；自绘样式，非 borderless（后者快照退 🚫）
            HStack(spacing: 6) {
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { step in
                    let active = abs(model.manualPercent - step) < 0.5
                    Button { model.setManualPercent(step) } label: {
                        Text(step == 0 ? "静音" : "\(Int(step))%")
                            .font(.caption2.weight(active ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? AnyShapeStyle(Color.blue.gradient)
                                             : AnyShapeStyle(Color.secondary.opacity(0.08))))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SegmentedItemButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }

    var autoContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "apple.logo")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("风扇由 macOS 系统调度")
                .font(.callout)
            Text("FanCtl 不介入，与原生行为完全一致")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 系统调度下的实时转速读数（读 status.json，App 侧不重算控制语义）：
            // 让"不介入"不再是空态——用户能看到系统此刻把风扇开到多少（统一数据条样式）
            if model.daemonAlive && !model.fans.isEmpty {
                statStrip(model.fans.map { fan in
                    (PanelFormat.rpmText(fan.actualRPM),
                     fan.id == 0 ? "左风扇 RPM" : "右风扇 RPM", nil)
                })
                .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // AI 自动接管：展示实时意图 + 可选目标温度（性能/均衡/静音）
    var aiContent: some View {
        let cur = max(model.cpuTemp, model.gpuTemp)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.callout).foregroundStyle(.purple.gradient)
                // dead 态语义诚实：守护进程停更时不再断言"自动接管"（快照审查 R20）
                Text(model.daemonAlive ? "AI 自动接管" : "AI 控制 · 数据停更")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(cur > 1 ? "\(Int(cur))°" : "--")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(MonitorStyle.color(cur).gradient)
                    .contentTransition(.numericText()).animation(.snappy, value: cur)
            }
            // 实时意图（daemon 单一数据源，与实际控制同源）+ 电池/夜间目标放宽胶囊 + 当前输出。
            // 电池/夜间提示做成行内胶囊（与意图胶囊同行高）：它们是持续状态而非事件，
            // 独立成行会在与其他提示叠加时突破 200pt 槽位（曾最坏 ~249pt，学习状态条被裁）
            HStack(spacing: 6) {
                if let i = model.aiIntent {
                    let s = Self.intentStyle(i)
                    HStack(spacing: 4) {
                        Image(systemName: s.0).font(.caption.weight(.bold))
                        Text(i.label).font(.caption.weight(.medium))
                            .lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(s.1)
                    .padding(.horizontal, panelChipHInset).padding(.vertical, 3)
                    .background(Capsule().fill(s.1.opacity(0.15)))
                    .id(i)
                    .transition(.opacity)
                    // layoutPriority：意图是本行主信息，空间不足时优先完整显示；
                    // 电池/体感/夜间胶囊与"经验"允许被截断（次要状态）
                    .layoutPriority(1)
                } else {
                    Text(model.controlReason == .aiIdle ? "风扇已交还系统" : "AI 状态同步中")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, panelChipHInset).padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.12)))
                        .id("pending")
                        .transition(.opacity)
                        .layoutPriority(1)
                }
                if model.onBattery && model.batterySaver {
                    adaptiveChip(icon: "battery.50", text: "电池 +4°", color: .green,
                                 help: "电池供电 · 目标自动放宽 +4°（更安静省电），与曲线\"电池安静档\"同语义")
                }
                if let pc = model.palmComp, pc > 0.5 {
                    adaptiveChip(icon: "hand.raised.fill", text: "体感 -\(Int(pc.rounded()))°", color: .cyan,
                                 help: "掌托 \(Int(model.palmRestTemp ?? 40))°C 超过舒适阈值：目标自动收紧（体感补偿）")
                }
                if model.nightOverride {
                    adaptiveChip(icon: "moon.stars.fill", text: "夜间 +4°", color: .teal,
                                 help: "夜间安静档（22:00–8:00）· AI 目标放宽 +4°，更安静")
                }
                Spacer(minLength: 2)
                if let ln = model.learnedNow {
                    Text("经验 \(Int(ln))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help("当前温度下，本机经验地图认为稳住温度所需的风量")
                        .contentTransition(.numericText())
                        .animation(.snappy, value: ln)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.aiIntent)
            .animation(.smooth(duration: 0.3), value: model.onBattery && model.batterySaver)
            // v7 曲线+AI 协同可视化：曲线基准（刻度线）vs AI 实际（填充条）
            // 直观展示"曲线=期望转速基准，AI=自适应修正"两层如何共同决定最终转速。
            // AI 空闲交还时隐藏：applied=0% 会显示"AI 放松 −N%"，但交还态没有 AI 决策，标签误导
            if let curve = model.curveTargetPercent, model.controlReason != .aiIdle {
                curveAIComboBar(curve: curve, ai: model.appliedPercent)
                    .transition(.opacity)
            }
            // 单条优先级状态行（200pt 槽位只允许一条事件级提示）：
            //   后台空转（R78，有可执行动作）> 压不住（学习停滞）> 目标推荐 > 全力散热
            // 此前 4 个条件块可叠加到 2-3 行，最坏 ~249pt 超出 200pt 槽位，
            // 底部学习状态条被裁剪（违反"底部控件可见"约束）
            //
            // R78：后台空转排在**链首**的理由：某个进程白烧两三个核时，"目标压不住"
            // 只是它的后果之一；而且这一行带明确可执行动作（一键结束），用户看到就能
            // 立刻止血。仍只占一行，200pt 约束不变。
            if let spin = model.spinAlerts.first {
                HStack(spacing: 5) {
                    Image(systemName: spin.isHighConfidence ? "exclamationmark.octagon.fill" : "hourglass.circle.fill")
                        .font(.caption2)
                    // R82：进程名走中文辨识（exe 缺失时用哨兵给的原始名兜底），
                    // 原始可执行名仍在悬停说明里，不丢真身
                    Text("\(ProcessIdentity.displayName(executable: spin.exe ?? spin.name)) 空转 \(Int(spin.cpu ?? spin.peak ?? 0))%")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("· \(spin.heldText)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // R81：核验不过进程实例标识就不给点——按钮留在原位（用户看得见
                    // "这里本来能处理"），但禁用并说明原因，避免只凭 pid 误杀复用者。
                    Button(action: { confirmKillSpin(spin) }) {
                        Text(model.canKillSpin(spin) ? "结束" : "结束不可用")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.mini)
                    .disabled(!model.canKillSpin(spin))
                    .help(killSpinHelp(spin))
                }
                .foregroundStyle(spin.isHighConfidence ? .red : .orange)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((spin.isHighConfidence ? Color.red : Color.orange).opacity(0.14)))
                .help(spinAlertHelp(spin))
                .transition(.opacity)
            } else if model.targetUnreachable {
                Label("目标 \(Int(model.aiTargetTemp))°C 压不住 · 风扇已满速 · 学习暂停", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.orange.opacity(0.14)))
                    .help("散热已到极限仍压不到目标温度，AI 不会记录饱和输出（学习暂停）。建议改用均衡 76° 或静音 80°。")
                    .transition(.opacity)
            } else if model.calibrating {
                // 4.0 B2：校准观察期——AI 已选但学习表未成熟，daemon 语义化 auto 采样中。
                // 复用事件提示槽位（链首优先级最高），零高度变化
                HStack(spacing: 4) {
                    Image(systemName: "scope").font(.caption2)
                    Text("AI 校准中：先观察系统散热，采够即接管").font(.caption2.weight(.medium))
                }
                .foregroundStyle(.teal)
                .transition(.opacity)
            } else if let rec = model.aiRecommendedTarget, abs(rec - model.aiTargetTemp) > 0.5 {
                // #4: AI 目标推荐（首次进入且无学习数据时基于基线温度推荐，点击采纳）
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb").font(.caption2)
                    Text("建议目标 \(Int(rec))°（基于当前温度，点击采纳）")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.purple)
                .contentShape(Rectangle())
                .onTapGesture { model.setAITarget(rec) }
                .transition(.opacity)
            } else if model.aiHighEffort {
                // #12: AI 全力散热预提示（区别于 targetUnreachable：黄色无感叹号）
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").font(.caption.weight(.bold))
                    Text("AI 正在全力散热").font(.caption.weight(.medium))
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, panelChipHInset).padding(.vertical, 3)
                .background(Capsule().fill(.yellow.opacity(0.15)))
                .transition(.opacity)
            }
            // 目标温度选择：越高越安静、越低越凉
            PanelSegmentedPicker(items: [("性能 72°", 72.0), ("均衡 76°", 76.0), ("静音 80°", 80.0)],
                                 selection: Binding(get: { model.aiTargetTemp }, set: { model.setAITarget($0) }))
            // v7 曲线锚定后 AI 仍在自学习：展示学习状态（学习中/稳定/积累）+ 已掌握温度点覆盖
            learningStatus(points: model.learnedPoints,
                           samples: model.learnedSamples,
                           learning: model.learningRecently)
            // v3.7 决策透镜：为什么是这个转速（一行摘要，悬停看全量）
            if let t = model.decisionTrace {
                decisionTraceRow(t)
            }
            // v3.7 学习地图 + 冻结按钮（可折叠；≥2 采信点才可冻结）
            learnMapDisclosure(model, expanded: $learnMapExpanded)
            // 评测摘要：仅在无事件级提示时显示（有提示时优先让位，保证 200pt 内不裁剪）。
            // v3.4.1：单行 run-on（"评测 130 小时 · 均温 55° · …"）拆为 5 个紧凑磁贴——
            // 一行连读 5 指标难扫视；磁贴各占一格、数值/标签分层，悬停仍看完整账本。
            // 磁贴仅 31pt，替换原 14pt 行 +17pt，评测在场时事件行必缺席，槽位余量足够。
            if let m = model.aiMetrics, m.sampleCount > 0, !model.targetUnreachable,
               !model.aiHighEffort,
               model.aiRecommendedTarget == nil || abs(model.aiRecommendedTarget! - model.aiTargetTemp) <= 0.5,
               model.decisionTrace == nil {   // v3.7：透镜行在场时让位（同为解释性内容，互斥防 216pt 裁剪）
                let eval = PanelFormat.evaluationText(m)
                statStrip([
                    (PanelFormat.compactDuration(eval.seconds), "评测", nil),
                    ("\(Int(m.averageTemp.rounded()))°", "均温", nil),
                    (String(format: "%.1f°", m.temperatureStdDev), "波动", nil),
                    ("\(Int(m.averageOutput.rounded()))%", "均输出", nil),
                    (PanelFormat.compactDuration(eval.highSeconds), "超温",
                     m.highTempSeconds > 60 ? Color.orange : nil),
                ])
                .help(eval.full)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // v7 曲线+AI 协同可视化（紧凑 2 行）：
    // 一条 0-100% 轨道，紫色填充 = AI 实际输出，灰色刻度线 = 用户曲线基准。
    // 刻度线位置 = "用户期望转速"，填充条到紫色 = "AI 最终输出"，
    // 两者间距 = "AI 自适应修正量"（散热压不住则加码、散热好则放松）。
    // 千位分隔转速文本（"2,858"）在 FanCtlAppCore.PanelFormat.rpmText，与 FanRow 同风格

    // 统一数据条：单容器 + 发丝分隔线（苹果天气/股市同款语言），
    // 替代各处独立小盒子——盒群视觉碎，发丝分隔一体感强
    private func statStrip(_ items: [(value: String, label: String, accent: Color?)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, m in
                VStack(spacing: 1) {
                    Text(m.value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(m.accent ?? Color(.secondaryLabelColor))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(m.label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(alignment: .trailing) {
                    if i < items.count - 1 {
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1).frame(height: 22)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))
    }

    // 自适应状态胶囊：空间足够显示"图标+文字"，不足时降级为纯图标（悬停仍有完整说明）。
    // ViewThatFits 避免"图标+省略号"的尴尬截断（旧 lineLimit(1) 无降级路径）；
    // 两个变体都 fixedSize——压缩由 ViewThatFits 的选择完成，不由布局挤压完成
    private func adaptiveChip(icon: String, text: String, color: Color, help: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(text, systemImage: icon)
                .font(.caption2.weight(.medium)).foregroundStyle(color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, panelChipHInset).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
            Image(systemName: icon)
                .font(.caption2.weight(.medium)).foregroundStyle(color)
                .padding(.horizontal, panelChipHInset).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .help(help)
        .transition(.opacity)
    }

    private func curveAIComboBar(curve: Double, ai: Double) -> some View {
        let curveC = min(max(curve, 0), 100)
        let aiC = min(max(ai, 0), 100)
        let diff = aiC - curveC
        let hasDiff = abs(diff) >= 2
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10)).foregroundStyle(.purple.opacity(0.7))
                Text("曲线 × AI 协同")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hasDiff {
                    Text((diff > 0 ? "AI 加码 +" : "AI 放松 ") + "\(Int(abs(diff)))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(diff > 0 ? .orange : .green)
                        .transition(.opacity)
                        // 出现/消失仍要淡入淡出，但补间只按「在不在」键值——按 diff 键值等于每拍演一次
                        .animation(.snappy, value: hasDiff)
                } else {
                    Text("AI 贴合曲线")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                // 「当前输出」每拍随 AI 微调（R60 实测：pct 类每拍 RSS +9.3MB，temp 类只 1.8MB）
                // ⇒ 同族规则（R47/R49）：每拍抖动的量不挂数字转场，等宽直读。
                Text("→ \(Int(aiC))%")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, .indigo],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * aiC / 100))
                        .shadow(color: .purple.opacity(0.4), radius: 2.5, y: 0.5)
                    if curveC > 2 && curveC < 98 {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, w * curveC / 100)
                    }
                }
            }
            .frame(height: 7)
            .animation(.snappy(duration: 0.4), value: aiC)
            .animation(.snappy(duration: 0.4), value: curveC)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.purple.opacity(0.05)))
    }

    // AI 意图的图标与色彩（与守护进程 AIIntent 一一对应）
    private static func intentStyle(_ i: AIIntent) -> (String, Color) {
        switch i {
        case .rising: return ("arrow.up.right", .orange)
        case .falling: return ("arrow.down.right", .green)
        case .holding: return ("equal", .blue)
        }
    }

    // AI 学习状态：曲线锚定后 AI 仍持续自学习（EMA 稳态采样），
    // 用"状态点 + 已掌握温度点覆盖条"直观表达"这台机器的热经验正在积累/已建立"。
    // 三种状态：
    //   learning  — 最近 120s 内有稳态采样（绿点脉冲）→ "AI 学习中"
    //   stable    — 已有经验但当前未采样（温度偏离目标/负载变化）→ "AI 已稳定 · 持续微调"
    //   coldStart — 尚无任何已采信经验 → "AI 正在学习散热规律"
    private func learningStatus(points: Int, samples: Int, learning: Bool) -> some View {
        let total = TempHistogram.bucketCount
        let coverage = total > 0 ? min(max(Double(points) / Double(total), 0), 1) : 0
        let state: AILearnState = learning ? .learning : (points > 0 ? .stable : .coldStart)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LearningDot(state: state)
                Text(state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.color)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: state)
                Spacer(minLength: 4)
                Text(points > 0 ? "已掌握 \(points)/\(total) 点" : "已积累 \(samples) 样本")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: points)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            // 学习覆盖进度条：已采信温度点 / 全部温度桶（40~96°C）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(state.color.gradient)
                        .frame(width: max(3, geo.size.width * coverage))
                        .shadow(color: state.color.opacity(0.4), radius: 2, y: 0.5)
                }
            }
            .frame(height: 4)
            .animation(.smooth(duration: 0.4), value: coverage)
            .help("AI 持续学习这台机器稳住每个温度所需的风量，并结合你的曲线基准微调。已掌握表示该温度点有足够采样被采信。")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(state.color.opacity(0.06)))
    }
}

// MARK: - v3.7 决策透镜 + 学习地图 + 冻结曲线

extension ContentView {

    // 决策透镜：一行"为什么是这个转速"——目标/误差/学习值/保持原因。
    // 悬停 .help 给全量解释；不新增 tab、不展开新卡片，高度预算内
    fileprivate func decisionTraceRow(_ t: DecisionTrace) -> some View {
        let errText: String
        if let e = t.error {
            errText = e > 0.5 ? "+\(Int(e.rounded()))°" : (e < -0.5 ? "\(Int(e.rounded()))°" : "±0")
        } else { errText = "-" }
        var reasons: [String] = []
        if t.idle == true { reasons.append("空闲交还中") }
        if t.hysteresisHold == true { reasons.append("迟滞保持") }
        if let g = t.guardSeconds, g > 0 { reasons.append("循环抑制 \(Int(g / 60)) 分钟") }
        let reasonText = reasons.isEmpty ? "" : " · " + reasons.joined(separator: "、")
        return HStack(spacing: 5) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("目标 \(t.target.map { Int($0.rounded()).description } ?? "-")° · 当前 \(t.temp.map { Int($0.rounded()).description } ?? "-")° · 误差 \(errText) · 学到 \(t.learned.map { Int($0.rounded()).description + "%" } ?? "无")\(reasonText)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .help(t.explanation)
    }

    // 学习地图（可折叠）：采信桶温度→风量折线 + 冻结按钮。
    // 自绘展开行而非 DisclosureGroup：系统三角把整块标签右推 ~10pt（快照实测文字落在
    // 57pt，而上方透镜行的文字在 47pt）——同一张卡里两行文字不同列。自己排布后
    // chevron 与 ⊕ 同列、文字与透镜行同列，展开内容顺同一列缩进。
    fileprivate func learnMapDisclosure(_ model: FanModel,
                                        expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        // 占位宽按上方透镜行的 scope 图标盒子取（scope 墨迹 28..39.5、
                        // 文字落在 47；chevron 自身只有 4pt 墨迹、自然盒 ~7pt）。
                        // 不钉这格两行文字差 7.5pt；钉 11 还差 3.5pt，钉到 14 才同列。
                        // alignment .leading 让箭头墨迹仍回到 28 那一列。
                        .frame(width: 14, alignment: .leading)
                    Text("学习地图（\(model.learnMap.count) 点）")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
            if expanded.wrappedValue {
                learnMapContent(model)
                    .padding(.leading, 19)   // 与标签文字同列（27+14+5）
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func learnMapContent(_ model: FanModel) -> some View {
        if model.learnMap.isEmpty {
            Text("暂无采信数据——AI 在稳态时记录温度与风量的对应关系，正常使用数小时后出现")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            // v3.7：展开内容整体限高——无约束时 Charts 自适应高度会溢出 216pt 卡
            //（快照 lens 实测溢出盖住底部按钮）。实际叠高 ~104pt（图 72+顶白 2 / 间距 6 /
            // 按钮 24，freezeHint 在场再加一行），超出 100pt 限高框的部分由 326pt 槽位的
            // 余量吸收——槽位才是硬预算，快照 lens 复验按钮不被裁。
            VStack(alignment: .leading, spacing: 6) {
                LearnMapView(points: model.learnMap)
                    .frame(height: 72)
                    .padding(.top, 2)   // Y 轴顶标"100"不被裁（快照 lens 实测裁半）
                if let hint = model.freezeHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.freezeCurveFromLearn()
                } label: {
                    Label("冻结为曲线快照", systemImage: "camera.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(PressableButtonStyle())
                .controlSize(.small)
                .disabled(!model.canFreezeCurve)
                .help(model.canFreezeCurve
                      ? "把 AI 学到的稳态经验转成普通曲线（快照）。之后 AI 继续学习，快照不跟进；安全兜底不变。"
                      : "至少需要 2 个采信温度点（正常使用几小时后达成）")
            }
            .frame(height: 100, alignment: .top)
        }
    }
}
