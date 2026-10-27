using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FairCopy;

public class LLMException(string message) : Exception(message)
{
    public static LLMException ServerUnavailable() => new(Lang.T(
        "Сервер модели не отвечает (LM Studio, 127.0.0.1:1234)",
        "The model server is not responding (LM Studio, 127.0.0.1:1234)"));

    public static LLMException Unauthorized() => new UnauthorizedLLMException(Lang.T(
        "LM Studio требует API-токен: меню FairCopy → «Токен LM Studio…»",
        "LM Studio requires an API token: FairCopy menu → \"LM Studio Token…\""));

    public static LLMException NoModel() => new(Lang.T("Нет загруженных моделей в LM Studio", "No models available in LM Studio"));

    public static LLMException OnlyReasoning() => new(Lang.T(
        "Модель потратила весь ответ на рассуждения и не выдала текст. Выберите другую модель или отключите у неё «Thinking» в LM Studio.",
        "The model spent the whole answer on reasoning and returned no text. Pick another model or turn off its “Thinking” in LM Studio."));

    public static LLMException Http(int code, string body) => new($"HTTP {code}: {(body.Length > 200 ? body[..200] : body)}");
}

public sealed class UnauthorizedLLMException(string message) : LLMException(message);

/// Клиент OpenAI-совместимого сервера LM Studio. Модель грузится «на лету» (JIT)
/// по первому запросу и выгружается через `ttl` секунд простоя, освобождая память.
public sealed class LLMClient
{
    public static readonly LLMClient Shared = new();

    public const string LMStudioURL = "http://127.0.0.1:1234/v1";

    static readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };

    /// Можно указать другой OpenAI-совместимый сервер: настройка baseURL или env AIEDITOR_URL
    /// (например, LM Studio на другом компьютере в сети).
    public string BaseURL =>
        (Environment.GetEnvironmentVariable("AIEDITOR_URL") ?? AppSettings.Shared.BaseURL ?? LMStudioURL).TrimEnd('/');

    public bool IsLMStudio => BaseURL == LMStudioURL;

    /// Хранилище токена (в приложении — Диспетчер учётных данных Windows). Env LM_API_TOKEN — для CLI.
    public Func<string?> ReadToken { get; set; } = () => null;

    string? Token => Environment.GetEnvironmentVariable("LM_API_TOKEN") ?? ReadToken();

    HttpRequestMessage Request(HttpMethod method, string path)
    {
        var req = new HttpRequestMessage(method, BaseURL + "/" + path);
        if (Token is { Length: > 0 } t) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", t);
        return req;
    }

    public static readonly string LmsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".lmstudio", "bin",
        OperatingSystem.IsWindows() ? "lms.exe" : "lms");

    public int IdleTTL { get; set; } = AppSettings.Shared.Ttl;

    public static readonly string[] PreferredModels = ["gemma-4-12b", "qwen3.5-9b"];

    public string? Model
    {
        get => AppSettings.Shared.Model;
        set { AppSettings.Shared.Model = value; AppSettings.Shared.Save(); }
    }

    public async Task<List<string>> ListModelsAsync(CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(2));
        using var resp = await http.SendAsync(Request(HttpMethod.Get, "models"), cts.Token);
        if (resp.StatusCode == HttpStatusCode.Unauthorized) throw LLMException.Unauthorized();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(cts.Token));
        return doc.RootElement.GetProperty("data").EnumerateArray()
            .Select(m => m.GetProperty("id").GetString()!)
            .Where(id => !id.Contains("embed")).ToList();
    }

    /// Поднимает сервер LM Studio, если он не запущен (`lms server start`).
    public async Task EnsureServerAsync(CancellationToken ct = default)
    {
        try { await ListModelsAsync(ct); return; }
        catch (UnauthorizedLLMException) { throw; }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { if (!IsLMStudio) throw LLMException.ServerUnavailable(); }
        try
        {
            Process.Start(new ProcessStartInfo(LmsPath, "server start")
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
            });
        }
        catch { throw LLMException.ServerUnavailable(); }
        for (int i = 0; i < 40; i++)
        {
            await Task.Delay(500, ct);
            try { await ListModelsAsync(ct); return; } catch when (!ct.IsCancellationRequested) { }
        }
        throw LLMException.ServerUnavailable();
    }

    public async Task<string> ResolveModelAsync(CancellationToken ct = default)
    {
        var models = await ListModelsAsync(ct);
        if (Model is { } m && models.Contains(m)) return m;
        foreach (var pref in PreferredModels)
            if (models.FirstOrDefault(x => x.Contains(pref, StringComparison.OrdinalIgnoreCase)) is { } found) return found;
        return models.FirstOrDefault() ?? throw LLMException.NoModel();
    }

    sealed class Body
    {
        public required string Model { get; init; }
        public required List<ChatMessage> Messages { get; init; }
        public double Temperature { get; init; }
        [JsonPropertyName("max_tokens")] public int MaxTokens { get; init; }
        public bool Stream { get; init; }
        public int Ttl { get; init; }
        /// Gemma 4 / Qwen по умолчанию могут «думать» перед ответом — для правки текста это
        /// только лишние секунды, поэтому выключаем рассуждения. Одни модели слушаются
        /// переменной шаблона чата, другие (Gemma 4 26B-A4B) — только `reasoning_effort`.
        [JsonPropertyName("chat_template_kwargs")] public Dictionary<string, bool> ChatTemplateKwargs { get; } = new() { ["enable_thinking"] = false };
        [JsonPropertyName("reasoning_effort")] public string ReasoningEffort => "none";
    }

    /// Стримит ответ; `onText` получает весь очищенный текст на текущий момент.
    public async Task<string> CompleteAsync(List<ChatMessage> messages, int? maxTokens = null, double temperature = 0.2,
                                            Action<string>? onText = null, CancellationToken ct = default)
    {
        await EnsureServerAsync(ct);
        var modelID = await ResolveModelAsync(ct);

        int inputChars = messages.LastOrDefault()?.Content.Length ?? 0;
        var body = new Body
        {
            Model = modelID, Messages = messages, Temperature = temperature,
            MaxTokens = maxTokens ?? Math.Max(512, inputChars * 2), Stream = true, Ttl = IdleTTL,
        };
        var req = Request(HttpMethod.Post, "chat/completions");
        req.Content = new StringContent(JsonSerializer.Serialize(body, FairCopy.Shared.Json), Encoding.UTF8, "application/json");

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(300));
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        if (resp.StatusCode == HttpStatusCode.Unauthorized) throw LLMException.Unauthorized();
        if (resp.StatusCode != HttpStatusCode.OK)
            throw LLMException.Http((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(cts.Token));

        var raw = new StringBuilder();
        bool reasoned = false;
        using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(cts.Token), Encoding.UTF8);
        while (await reader.ReadLineAsync(cts.Token) is { } line)
        {
            if (!line.StartsWith("data: ")) continue;
            var payload = line[6..];
            if (payload == "[DONE]") break;
            JsonElement delta;
            try
            {
                using var doc = JsonDocument.Parse(payload);
                var choices = doc.RootElement.GetProperty("choices");
                if (choices.GetArrayLength() == 0) continue;
                delta = choices[0].GetProperty("delta").Clone();
            }
            catch (JsonException) { continue; }
            if (delta.TryGetProperty("reasoning_content", out var r) && r.ValueKind == JsonValueKind.String
                && r.GetString()!.Length > 0) reasoned = true;
            if (!delta.TryGetProperty("content", out var c) || c.ValueKind != JsonValueKind.String) continue;
            raw.Append(c.GetString());
            onText?.Invoke(Prompts.Clean(raw.ToString()));
        }
        var result = Prompts.Clean(raw.ToString());
        // рассуждения съели весь лимит токенов — без этого окно просто осталось бы пустым
        if (result.Length == 0 && reasoned && maxTokens != 1) throw LLMException.OnlyReasoning();
        return result;
    }

    public sealed record LoadedModel(string Identifier, string? Status, long? SizeBytes);

    /// Что сейчас лежит в памяти LM Studio (`lms ps --json`; CLI ходит в LM Studio без API-токена).
    public async Task<List<LoadedModel>?> LoadedModelsAsync()
    {
        var out_ = await RunLmsAsync("ps", "--json");
        if (out_ is null) return null;
        try { return JsonSerializer.Deserialize<List<LoadedModel>>(out_, FairCopy.Shared.Json); }
        catch (JsonException) { return null; }
    }

    /// «Охлаждение»: выгружаем нашу модель из памяти, чужие модели не трогаем.
    public async Task UnloadAsync()
    {
        string? ours;
        try { ours = await ResolveModelAsync(); } catch { ours = Model; }
        foreach (var m in await LoadedModelsAsync() ?? [])
            if (ours is null || m.Identifier == ours) await RunLmsAsync("unload", m.Identifier);
    }

    static async Task<string?> RunLmsAsync(params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(LmsPath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            var out_ = await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            return out_;
        }
        catch { return null; }
    }

    /// Загружает модель заранее (после запуска и выхода из сна): первая правка иначе ждёт
    /// 10–12 с, пока LM Studio поднимает веса. Шлём тот же промпт исправления —
    /// заодно в кэше оказывается его начало, общее для всех запросов.
    public async Task PrewarmAsync()
    {
        try { await CompleteAsync(Prompts.Messages(EditMode.Fix, null, "", "ок"), maxTokens: 1); } catch { }
    }
}
