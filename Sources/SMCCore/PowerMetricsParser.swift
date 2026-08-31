import Foundation

// MARK: - powermetrics 输出解析（纯函数，fanctld 与测试共用）
//
// v2.6 曾传 "-u W" 参数——powermetrics 没有 "-u"（单位）选项（macOS 26 实测
// "invalid option -- u"），每次采样立即以 usage error 退出，分项功耗前馈自上线起
// 静默失效（连续失败 3 次后值过期，且无任何日志可见）。修复：去掉该参数；
// powermetrics 功耗行默认单位为 mW（如 "CPU Power: 789 mW"），按后缀换算为 W。
//
// 解析约定：取 key 后第一个以数字/符号开头的空白分隔词作为数值（千分位逗号
// 并入数值，"12,345 mW" → 12345 mW——此前按标点切分会被采信成 12 mW，错 1000 倍
// 且通过范围检查）；单位优先取数值词内紧邻后缀（"789mW"），否则取下一个词前缀。

public enum PowerMetricsParser {
    /// 解析形如 "CPU Power: 789 mW" / "GPU Power: 12.3 W" 的行，返回瓦特值。
    /// 同 key 多次出现取最后一次（powermetrics -n 多样本时取最新）；
    /// 无匹配/数值无效/超范围 (0.01, 500) W 返回 nil。
    public static func watts(in output: String, key: String) -> Double? {
        var last: Double? = nil
        for line in output.split(separator: "\n") {
            guard let keyRange = line.range(of: key) else { continue }
            let words = line[keyRange.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let vIdx = words.firstIndex(where: { w in
                w.first.map { $0.isNumber || $0 == "-" || $0 == "." } ?? false
            }) else { continue }
            let numEnd = words[vIdx].firstIndex {
                !($0.isNumber || $0 == "." || $0 == "-" || $0 == ",")
            } ?? words[vIdx].endIndex
            var unit = words[vIdx][numEnd...]          // 词内紧邻单位："789mW"
            if unit.isEmpty, vIdx + 1 < words.count {
                unit = words[vIdx + 1].prefix(2)       // 空格分隔单位："789 mW"
            }
            let cleaned = words[vIdx][..<numEnd].replacingOccurrences(of: ",", with: "")
            guard let v = Double(cleaned) else { continue }
            let watts: Double
            if unit.hasPrefix("m") { watts = v / 1000.0 }        // mW
            else if unit.hasPrefix("k") { watts = v * 1000.0 }   // kW（防御未来格式）
            else { watts = v }                                   // W
            if watts > 0.01, watts < 500 { last = watts }
        }
        return last
    }
}
