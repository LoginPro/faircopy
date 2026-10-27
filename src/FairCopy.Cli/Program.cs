using System.Text;
using FairCopy;

// faircopy-cli --dump-prompts            — все промпты на фиксированных входных данных (сверка с macOS)
// faircopy-cli fix|style <id>|translate <язык> <текст>   — разовая правка через LM Studio
// faircopy-cli models                    — модели, которые видит сервер

// Вывод — сырыми байтами UTF-8 с \n: консоль Windows и PowerShell иначе перекодируют текст.
var stdout = Console.OpenStandardOutput();
var stderr = Console.OpenStandardError();
void Write(string s) => Raw(stdout, s);
void WriteError(string s) => Raw(stderr, s + "\n");
static void Raw(Stream to, string s) { var b = Encoding.UTF8.GetBytes(s); to.Write(b, 0, b.Length); to.Flush(); }

if (args.Length == 0)
{
    Write("usage: faircopy-cli --dump-prompts | models | fix <text> | style <id> <text> | translate <language> <text>\n");
    return 2;
}

try
{
    switch (args[0])
    {
        case "--dump-prompts":
            Write(PromptDump.Run());
            return 0;
        case "models":
            await LLMClient.Shared.EnsureServerAsync();
            foreach (var m in await LLMClient.Shared.ListModelsAsync()) Write(m + "\n");
            Write("→ " + await LLMClient.Shared.ResolveModelAsync() + "\n");
            return 0;
        case "fix" when args.Length >= 2:
            return await Run(Prompts.Messages(EditMode.Fix, null, "", string.Join(' ', args[1..]), dictionary: Dict()));
        case "style" when args.Length >= 3:
            var style = StyleStore.Shared.Find(args[1]) ?? throw new ArgumentException("нет стиля " + args[1]);
            return await Run(Prompts.Messages(EditMode.Style, style, "", string.Join(' ', args[2..]), dictionary: Dict()));
        case "translate" when args.Length >= 3:
            return await Run(Prompts.Messages(EditMode.Translate, null, args[1], string.Join(' ', args[2..]), dictionary: Dict()));
        default:
            Write("unknown command\n");
            return 2;
    }
}
catch (Exception e)
{
    WriteError(e.Message);
    return 1;
}

static List<string> Dict() => AppSettings.Shared.Dictionary;

async Task<int> Run(List<ChatMessage> messages)
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var result = await LLMClient.Shared.CompleteAsync(messages);
    Write(result + "\n");
    WriteError($"[{sw.Elapsed.TotalSeconds:F1} с]");
    return 0;
}
