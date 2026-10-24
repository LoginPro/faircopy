import SwiftUI

/// Пословный дифф «оригинал → результат» для подсветки правок, как в Telegram:
/// удалённое — красным зачёркнутым, добавленное — синим подчёркнутым.
enum WordDiff {
    enum Op { case same(String), removed(String), added(String) }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var curIsWord: Bool? = nil
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber
            if isWord, curIsWord == true {
                cur.append(ch)
            } else if ch.isWhitespace, curIsWord == false, cur.allSatisfy(\.isWhitespace) {
                cur.append(ch)
            } else {
                if !cur.isEmpty { tokens.append(cur) }
                cur = String(ch)
                curIsWord = isWord ? true : (ch.isWhitespace ? false : nil)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    static func diff(_ a: String, _ b: String) -> [Op] {
        let x = tokenize(a), y = tokenize(b)
        let n = x.count, m = y.count
        guard n * m <= 4_000_000 else { return [.removed(a), .added(b)] }
        // LCS по токенам
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { ops.append(.same(x[i])); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { ops.append(.added(y[j])); j += 1 }
            else { ops.append(.removed(x[i])); i += 1 }
        }
        return group(ops)
    }

    /// Собирает соседние правки в блоки «сначала всё удалённое, потом всё добавленное»,
    /// чтобы не было чересполосицы вида «р̶а̶д̶ Рад ч̶т̶о̶ , что».
    private static func group(_ ops: [Op]) -> [Op] {
        var out: [Op] = []
        var rem = "", add = ""
        func flush() {
            if !rem.isEmpty { out.append(.removed(rem)) }
            if !add.isEmpty { out.append(.added(add)) }
            rem = ""; add = ""
        }
        for (k, op) in ops.enumerated() {
            switch op {
            case .removed(let t): rem += t
            case .added(let t): add += t
            case .same(let t):
                // одиночный пробел между двумя правками считаем частью правки
                if t.allSatisfy(\.isWhitespace), !(rem.isEmpty && add.isEmpty),
                   k + 1 < ops.count, !isSame(ops[k + 1]) {
                    rem += t; add += t
                } else {
                    flush(); out.append(op)
                }
            }
        }
        flush()
        return out
    }

    private static func isSame(_ op: Op) -> Bool { if case .same = op { return true }; return false }

    static func attributed(_ a: String, _ b: String) -> AttributedString {
        var result = AttributedString()
        for op in diff(a, b) {
            switch op {
            case .same(let t):
                result += AttributedString(t)
            case .removed(let t):
                var s = AttributedString(t)
                s.foregroundColor = .red
                s.strikethroughStyle = .single
                result += s
            case .added(let t):
                var s = AttributedString(t)
                s.foregroundColor = .accentColor
                s.underlineStyle = .single
                result += s
            }
        }
        return result
    }
}

/// Кусок диффа для окна редактора: либо неизменный текст, либо правка «было → стало».
struct DiffSegment: Identifiable {
    let id: Int
    let same: String?
    let removed: String
    let added: String
    /// Ключ для пояснений: переживает ручную правку результата, пока сама правка не изменилась.
    /// Номер повтора различает одинаковые правки (две вставленные запятые — разные правила).
    var key = ""

    var isChange: Bool { same == nil }
}

extension WordDiff {
    static func segments(_ a: String, _ b: String) -> [DiffSegment] {
        var out: [DiffSegment] = []
        var rem = "", add = ""
        var seen: [String: Int] = [:]
        func flush() {
            if !rem.isEmpty || !add.isEmpty {
                let pair = rem + "→" + add
                seen[pair, default: 0] += 1
                out.append(.init(id: out.count, same: nil, removed: rem, added: add, key: "\(seen[pair]!)#\(pair)"))
            }
            rem = ""; add = ""
        }
        for op in diff(a, b) {
            switch op {
            case .removed(let t): rem += t
            case .added(let t): add += t
            case .same(let t): flush(); out.append(.init(id: out.count, same: t, removed: "", added: ""))
            }
        }
        flush()
        return out
    }
}

/// Перенос «по словам» для набора отдельных вьюх (слов и правок).
struct FlowLayout: Layout {
    struct LineBreak: LayoutValueKey { static let defaultValue = false }
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 420, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(bounds.width, subviews).frames
        for (i, f) in frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                              proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func arrange(_ maxW: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            if s[LineBreak.self] {
                frames.append(.zero)
                y += max(lineH, 16); x = 0; lineH = 0
                continue
            }
            var size = s.sizeThatFits(.unspecified)
            // длинная правка шире строки — пусть переносится сама внутри своей ширины
            if size.width > maxW { size = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)) }
            if x > 0, x + size.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
        return (CGSize(width: maxW, height: y + lineH), frames)
    }
}
