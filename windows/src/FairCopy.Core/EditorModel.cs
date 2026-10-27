using System.Diagnostics;

namespace FairCopy;

/// Состояние окна редактора: режим, стиль, язык, результат модели, дифф и пояснения правок.
/// Работает на потоке интерфейса; после любого изменения вызывает Changed — окно перерисовывается.
public sealed class EditorModel
{
    readonly StyleStore styles = StyleStore.Shared;
    readonly AppSettings settings = AppSettings.Shared;

    public event Action? Changed;

    public string Original { get; private set; } = "";
    public string Result { get; private set; } = "";
    public bool Running { get; private set; }
    public string? Error { get; private set; }
    public string Stats { get; private set; } = "";
    public bool ShowOriginal { get; set; }
    public List<DiffSegment> Segments { get; private set; } = [];
    public Dictionary<string, string> Explanations { get; } = [];
    public bool Explaining { get; private set; }
    public string? HoverKey { get; private set; }

    /// Приложение, из которого вызвали редактор (имя exe) — для запоминания стиля.
    public string? AppID { get; private set; }

    EditMode mode = EditMode.Fix;
    string styleID = StyleStore.Shared.Styles.FirstOrDefault()?.Id ?? Style.CustomID;
    /// Стиль поверх перевода (как «добавить стиль при переводе» в Telegram); null — без стиля.
    string? translateStyleID;
    bool editing;
    bool suppressRun;
    CancellationTokenSource? cts, explainCts;

    public EditMode Mode
    {
        get => mode;
        set { if (mode != value) { mode = value; AutoRun(); } }
    }

    public string StyleID
    {
        get => styleID;
        set { if (styleID != value) { styleID = value; if (value != Style.CustomID) AutoRun(); else Notify(); } }
    }

    public string? TranslateStyleID
    {
        get => translateStyleID;
        set { if (translateStyleID != value) { translateStyleID = value; if (value != Style.CustomID) AutoRun(); else Notify(); } }
    }

    public string CustomStyle
    {
        get => settings.CustomStyle;
        set { settings.CustomStyle = value; settings.Save(); }
    }

    public string Language
    {
        get => settings.Language;
        set
        {
            if (settings.Language == value) return;
            settings.Language = value;
            settings.Save();
            AutoRun();
        }
    }

    /// Ручная правка результата перед «Применить».
    public bool Editing
    {
        get => editing;
        set
        {
            if (editing == value) return;
            editing = value;
            if (!value) RefreshDiff();
            Notify();
        }
    }

    public Style? CurrentStyle => styleID == Style.CustomID ? Style.AdHoc(CustomStyle) : styles.Find(styleID);
    public Style? CurrentTranslateStyle =>
        translateStyleID == Style.CustomID ? Style.AdHoc(CustomStyle) : styles.Find(translateStyleID);
    public int ChangeCount => Segments.Count(s => s.IsChange);

    void Notify() => Changed?.Invoke();

    public void Start(string text, string? appID)
    {
        suppressRun = true;
        Original = text;
        AppID = appID;
        ShowOriginal = false;
        var pref = appID is not null && settings.RememberPerApp ? settings.AppPrefs.GetValueOrDefault(appID) : null;
        mode = pref?.EditMode ?? EditMode.Fix;
        if (pref?.StyleID is { } id) styleID = id;
        translateStyleID = pref?.TranslateStyleID;
        if (pref?.Language is { } lang) settings.Language = lang;
        ValidateStyles();
        suppressRun = false;
        Run();
    }

    /// Стиль могли удалить в настройках — тогда откатываемся на первый доступный.
    void ValidateStyles()
    {
        if (styleID != Style.CustomID && styles.Find(styleID) is null)
            styleID = styles.Styles.FirstOrDefault()?.Id ?? Style.CustomID;
        if (translateStyleID is { } t && t != Style.CustomID && styles.Find(t) is null) translateStyleID = null;
    }

    void AutoRun()
    {
        if (!suppressRun) Run(); else Notify();
    }

    public async void Run()
    {
        cts?.Cancel(); explainCts?.Cancel();
        var my = cts = new CancellationTokenSource();
        Result = ""; Error = null; Stats = ""; Running = true; editing = false;
        Segments = []; Explanations.Clear(); Explaining = false; HoverKey = null;
        ValidateStyles();
        Notify();

        var msgs = Prompts.Messages(mode, CurrentStyle, Language, Original, CurrentTranslateStyle, settings.Dictionary);
        var sw = Stopwatch.StartNew();
        try
        {
            var out_ = await LLMClient.Shared.CompleteAsync(msgs, onText: text =>
            {
                if (my.IsCancellationRequested) return;
                Result = text;
                Notify();
            }, ct: my.Token);
            if (my.IsCancellationRequested) return;
            Result = out_;
            Stats = Lang.T($"{sw.Elapsed.TotalSeconds:F1} с", $"{sw.Elapsed.TotalSeconds:F1} s");
            Running = false;
            RefreshDiff();
            Notify();
            if (mode == EditMode.Fix && settings.ExplainEdits) Explain();
        }
        catch (Exception e) when (my.IsCancellationRequested && e is OperationCanceledException) { }
        catch (Exception e)
        {
            if (my.IsCancellationRequested) return;
            Error = e is OperationCanceledException or TaskCanceledException
                ? Lang.T("Модель не ответила за 5 минут", "The model didn't answer in 5 minutes") : e.Message;
            Running = false;
            Notify();
        }
    }

    public void RefreshDiff() =>
        Segments = mode == EditMode.Fix && Result.Length > 0 ? WordDiff.Segments(Original, Result) : [];

    /// Второй, фоновый запрос: короткое объяснение каждой правки для подсказок при наведении.
    async void Explain()
    {
        var changes = Segments.Where(s => s.IsChange && !Explanations.ContainsKey(s.Key)).Take(15).ToList();
        if (changes.Count == 0) return;
        Explaining = true;
        Notify();
        var my = explainCts = new CancellationTokenSource();
        var msgs = Prompts.ExplainMessages(Original, Result, changes.Select(c => (c.Removed, c.Added)).ToList());
        string? raw = null;
        try { raw = await LLMClient.Shared.CompleteAsync(msgs, maxTokens: 70 * changes.Count + 60, ct: my.Token); }
        catch (Exception e) { Log.Write("пояснения: " + e.Message); }
        if (my.IsCancellationRequested) return;
        if (raw is not null && Prompts.ParseExplanations(raw, changes.Count) is { } list)
            for (int i = 0; i < list.Count; i++) Explanations[changes[i].Key] = list[i];
        Explaining = false;
        Notify();
    }

    /// Текст результата правят вручную (поле в режиме «Изменить»).
    public void SetResult(string text) => Result = text;

    public void FinishEditing()
    {
        Editing = false;
        if (mode == EditMode.Fix && settings.ExplainEdits) Explain();
    }

    public void Hover(string? key)
    {
        if (HoverKey == key) return;
        HoverKey = key;
        Notify();
    }

    /// Превращает разовое описание из «Свой стиль» в постоянный стиль.
    public void SaveCustomAsStyle()
    {
        var text = CustomStyle.Trim();
        if (text.Length == 0) return;
        var s = styles.Add(new Style
        {
            Id = Guid.NewGuid().ToString().ToUpperInvariant(), Emoji = "✍️",
            Name = text.Length > 24 ? text[..24] : text, Prompt = Style.AdHoc(text).Prompt,
        });
        if (mode == EditMode.Translate) translateStyleID = s.Id; else styleID = s.Id;
        Notify();
    }

    /// Запоминаем, в каком режиме и стиле применили текст в этом приложении.
    public void RememberForApp(string? name)
    {
        if (!settings.RememberPerApp || AppID is null) return;
        settings.AppPrefs[AppID] = new AppPref
        {
            Name = name ?? AppID, Mode = mode.Key(),
            StyleID = styleID == Style.CustomID ? null : styleID,
            TranslateStyleID = translateStyleID == Style.CustomID ? null : translateStyleID,
            Language = Language,
        };
        settings.Save();
    }

    public void Cancel()
    {
        cts?.Cancel(); explainCts?.Cancel();
        Running = false; Explaining = false; editing = false;
    }

    /// Текст подсказки под результатом (пусто — строку не показывать).
    public string HintText
    {
        get
        {
            if (mode != EditMode.Fix || editing || Running || ChangeCount == 0) return "";
            if (HoverKey is { } key)
                return Explanations.GetValueOrDefault(key)
                    ?? (Explaining ? Lang.T("Готовлю пояснение…", "Preparing an explanation…")
                                   : Lang.T("Пояснения к этой правке нет", "No explanation for this edit"));
            if (Explaining) return Lang.T("Готовлю пояснения к правкам…", "Preparing explanations…");
            if (!settings.ExplainEdits)
                return Lang.T($"Правок: {ChangeCount}. Пояснения выключены в настройках",
                              $"Edits: {ChangeCount}. Explanations are off in Settings");
            return Lang.T($"Правок: {ChangeCount}. Наведи на правку — объясню, почему так",
                          $"Edits: {ChangeCount}. Hover over an edit to see why");
        }
    }
}
