using System.Globalization;
using System.Text;

namespace FairCopy;

/// Пословный дифф «оригинал → результат» для подсветки правок, как в Telegram:
/// удалённое — красным зачёркнутым, добавленное — синим подчёркнутым.
public static class WordDiff
{
    public enum Kind { Same, Removed, Added }
    public readonly record struct Op(Kind Kind, string Text);

    /// Делит на слова, пробельные промежутки и отдельные знаки. Работает по графемам,
    /// чтобы эмодзи и буквы с диакритикой не разрывались.
    public static List<string> Tokenize(string s)
    {
        var tokens = new List<string>();
        var cur = new StringBuilder();
        bool? curIsWord = null;
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            var ch = (string)e.Current;
            var r = Rune.GetRuneAt(ch, 0);
            bool isWord = Rune.IsLetterOrDigit(r) || Rune.GetUnicodeCategory(r) is UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;
            bool isSpace = Rune.IsWhiteSpace(r);
            if (isWord && curIsWord == true)
                cur.Append(ch);
            else if (isSpace && curIsWord == false && cur.ToString().All(char.IsWhiteSpace))
                cur.Append(ch);
            else
            {
                if (cur.Length > 0) tokens.Add(cur.ToString());
                cur.Clear().Append(ch);
                curIsWord = isWord ? true : isSpace ? false : null;
            }
        }
        if (cur.Length > 0) tokens.Add(cur.ToString());
        return tokens;
    }

    public static List<Op> Diff(string a, string b)
    {
        var x = Tokenize(a);
        var y = Tokenize(b);
        int n = x.Count, m = y.Count;
        if ((long)n * m > 4_000_000) return [new(Kind.Removed, a), new(Kind.Added, b)];
        // LCS по токенам
        var dp = new int[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
            for (int j = m - 1; j >= 0; j--)
                dp[i, j] = x[i] == y[j] ? dp[i + 1, j + 1] + 1 : Math.Max(dp[i + 1, j], dp[i, j + 1]);
        var ops = new List<Op>();
        int p = 0, q = 0;
        while (p < n || q < m)
        {
            if (p < n && q < m && x[p] == y[q]) { ops.Add(new(Kind.Same, x[p])); p++; q++; }
            else if (q < m && (p == n || dp[p, q + 1] >= dp[p + 1, q])) { ops.Add(new(Kind.Added, y[q])); q++; }
            else { ops.Add(new(Kind.Removed, x[p])); p++; }
        }
        return Group(ops);
    }

    /// Собирает соседние правки в блоки «сначала всё удалённое, потом всё добавленное»,
    /// чтобы не было чересполосицы вида «р̶а̶д̶ Рад ч̶т̶о̶ , что».
    static List<Op> Group(List<Op> ops)
    {
        var out_ = new List<Op>();
        string rem = "", add = "";
        void Flush()
        {
            if (rem.Length > 0) out_.Add(new(Kind.Removed, rem));
            if (add.Length > 0) out_.Add(new(Kind.Added, add));
            rem = ""; add = "";
        }
        for (int k = 0; k < ops.Count; k++)
        {
            var op = ops[k];
            switch (op.Kind)
            {
                case Kind.Removed: rem += op.Text; break;
                case Kind.Added: add += op.Text; break;
                default:
                    // одиночный пробел между двумя правками считаем частью правки
                    if (op.Text.All(char.IsWhiteSpace) && !(rem.Length == 0 && add.Length == 0)
                        && k + 1 < ops.Count && ops[k + 1].Kind != Kind.Same)
                    {
                        rem += op.Text; add += op.Text;
                    }
                    else
                    {
                        Flush(); out_.Add(op);
                    }
                    break;
            }
        }
        Flush();
        return out_;
    }

    public static List<DiffSegment> Segments(string a, string b)
    {
        var out_ = new List<DiffSegment>();
        string rem = "", add = "";
        var seen = new Dictionary<string, int>();
        void Flush()
        {
            if (rem.Length > 0 || add.Length > 0)
            {
                var pair = rem + "→" + add;
                seen[pair] = seen.GetValueOrDefault(pair) + 1;
                out_.Add(new DiffSegment(out_.Count, null, rem, add, $"{seen[pair]}#{pair}"));
            }
            rem = ""; add = "";
        }
        foreach (var op in Diff(a, b))
        {
            switch (op.Kind)
            {
                case Kind.Removed: rem += op.Text; break;
                case Kind.Added: add += op.Text; break;
                default: Flush(); out_.Add(new DiffSegment(out_.Count, op.Text, "", "")); break;
            }
        }
        Flush();
        return out_;
    }
}

/// Кусок диффа для окна редактора: либо неизменный текст, либо правка «было → стало».
/// Key — ключ для пояснений: переживает ручную правку результата, пока сама правка не изменилась.
/// Номер повтора различает одинаковые правки (две вставленные запятые — разные правила).
public sealed record DiffSegment(int Id, string? Same, string Removed, string Added, string Key = "")
{
    public bool IsChange => Same is null;
}
