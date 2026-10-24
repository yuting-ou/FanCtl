// PanelCards —— 面板玻璃卡片样式与胶囊内边距真值（R89 自 PanelView 拆出）。
// cardStyle()/tintedCard() 被 GaugeViews 跨文件使用，保持 internal。
import SwiftUI


/// 面板内联胶囊（药丸形小标签）的统一横向内边距。此前 9/7/6/5 四种并存，
/// 而它们会并排出现在同一行里——横向不一，胶囊就"高矮齐、宽窄不齐"，
/// 里面的文字也落不到同一列（27+9=36 vs 27+7=34）。纵向仍按字号分（9pt 徽章 2、
/// 10~11pt 胶囊 3、决策原因胶囊 5），只有横向收成这一个真值。
/// 全 App 的胶囊一律引用它；字面量 9/6/5 由 TestsCore 的门禁钉死不得复活。
let panelChipHInset: CGFloat = 7

// MARK: - 卡片背景

// v3.4.4（用户定调回原生）：每卡独立 glassEffect，由 GlassEffectContainer 融合成
// 连续液态玻璃面——即 4b5394f 时代的外观（用户认可的版本）。方向性投影会经容器
// 融合后均匀化，右缘窄条暗带在原生观感下可接受。
private struct CardBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let base = content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        if snapshotPlainCards {
            base.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        } else {
            base.glassEffect(.regular, in: shape)
        }
    }
}


extension View {
    /// v3.4.1：快照模式下 glassEffect Capsule 退实心材质圆胶囊
    ///（ImageRenderer 离屏无法合成 Liquid Glass，渲染为系统黄色 🚫 占位）。
    @ViewBuilder
    func snapshotCapsule() -> some View {
        if snapshotPlainCards {
            self.background(.regularMaterial, in: Capsule())
        } else {
            self.glassEffect(.regular, in: Capsule())
        }
    }
}

extension View {  // 跨文件使用（TempGaugeCard 等），不能 private
    func cardStyle() -> some View { modifier(CardBackground()) }
    func tintedCard(_ tint: Color) -> some View { modifier(TintedCard(tint: tint)) }
}

// 带色彩渲染的玻璃卡（用于冲刺中 / 告警等需要强调的状态）
private struct TintedCard: ViewModifier {
    let tint: Color
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        let base = content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        if snapshotPlainCards {
            base.background(tint.opacity(0.18), in: shape)
                .overlay(shape.strokeBorder(tint.opacity(0.35)))
        } else {
            base.glassEffect(.regular.tint(tint.opacity(0.22)), in: shape)
        }
    }
}
