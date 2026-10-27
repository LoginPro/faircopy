using System.Diagnostics;
using FairCopy.Platform;
using static FairCopy.Lang;

namespace FairCopy.App;

/// Значок в трее, хоткеи и быстрая замена — то, что на macOS делает AppDelegate.
sealed class Controller(App app)
{
    const int EditorHotKeyID = 1, QuickHotKeyID = 2;

    readonly AppSettings settings = AppSettings.Shared;
    MessageWindow window = null!;
    HotKeys hotKeys = null!;
    TrayIcon tray = null!;
    ForegroundTracker foreground = null!;
    readonly EditorModel editorModel = new();
    EditorWindow? editor;
    TextTarget? editorTarget;
    bool working;

    public void Start()
    {
        Log.Write($"FairCopy {typeof(Controller).Assembly.GetName().Version} запущен, язык {Lang.Code}");
        window = new MessageWindow();
        Clipboard.Owner = window.Handle;
        foreground = new ForegroundTracker();
        LLMClient.Shared.ReadToken = Credentials.ReadToken;
        tray = new TrayIcon(window, Path.Combine(AppContext.BaseDirectory, "Assets"), Menu);
        hotKeys = new HotKeys(window);
        RegisterHotKeys();

        // после сна модель могла выгрузиться — прогреваем заново
        window.OnResume(PrewarmIfEnabled);

        _ = StartupAsync();

        // `--panel [fix|style|translate]` — открыть редактор сразу на тестовом тексте, без хоткея и чужих
        // программ (для проверки интерфейса и скриншотов; «Применить» только закрывает окно)
        var args = Environment.GetCommandLineArgs();
        int i = Array.IndexOf(args, "--panel");
        if (i >= 0) ShowTestPanel(i + 1 < args.Length ? args[i + 1] : null);
    }

    void ShowTestPanel(string? mode)
    {
        Log.Write("тестовое окно редактора: " + (mode ?? "fix"));
        try { ShowTestPanelCore(mode); }
        catch (Exception e) { Log.Write("тестовое окно редактора: " + e); }
    }

    void ShowTestPanelCore(string? mode)
    {
        EnsureEditor();
        editorTarget = null;
        editorModel.Start(T("короче я щас не смогу прийти потомучто машина сломалась может завтра норм будет",
                            "hey so I was thinking maybe we could grab lunch tmrw if your free lol let me know"), null);
        editorModel.Mode = mode switch { "style" => EditMode.Style, "translate" => EditMode.Translate, _ => EditMode.Fix };
        var (x, y) = TextBridge.CursorPosition();
        editor!.ShowAt((x, y, 0, 0));
    }

    void EnsureEditor()
    {
        if (editor is not null) return;
        editor = new EditorWindow(editorModel);
        editor.Applied += ApplyEditor;
        editor.Dismissed += CloseEditor;
    }

    async Task StartupAsync()
    {
        try { await LLMClient.Shared.EnsureServerAsync(); } // заранее, чтобы первый запрос был быстрее
        catch (Exception e) { Log.Write("сервер модели: " + e.Message); }
        if (settings.Prewarm) Warm(); else await RefreshModelState();
    }

    void RegisterHotKeys()
    {
        bool editor = hotKeys.Register(EditorHotKeyID, settings.EditorHotKey, () => { Log.Write("хоткей редактора"); OpenEditor(null); });
        bool quick = hotKeys.Register(QuickHotKeyID, settings.QuickHotKey, () => { Log.Write("хоткей быстрой замены"); _ = QuickFix(null); });
        Log.Write($"хоткеи {Display(settings.EditorHotKey)} {Display(settings.QuickHotKey)}, зарегистрированы: {editor} {quick}");
        var busy = new List<string>();
        if (!editor) busy.Add(Display(settings.EditorHotKey));
        if (!quick) busy.Add(Display(settings.QuickHotKey));
        if (busy.Count > 0)
            tray.Notify("FairCopy", T($"Сочетание {string.Join(", ", busy)} занято другим приложением.",
                                      $"{string.Join(", ", busy)} is already used by another app."), error: true);
    }

    static string Display(HotKeySpec k)
    {
        var parts = new List<string>();
        if ((k.Modifiers & HotKeySpec.Control) != 0) parts.Add("Ctrl");
        if ((k.Modifiers & HotKeySpec.Alt) != 0) parts.Add("Alt");
        if ((k.Modifiers & HotKeySpec.Shift) != 0) parts.Add("Shift");
        if ((k.Modifiers & HotKeySpec.Win) != 0) parts.Add("Win");
        parts.Add(k.Key is >= 0x30 and <= 0x5A ? ((char)k.Key).ToString() : $"#{k.Key}");
        return string.Join("+", parts);
    }

    // меню значка

    IReadOnlyList<MenuItem> Menu()
    {
        _ = RefreshModelState(); // к следующему открытию меню состояние будет свежим
        var (state, canWarm, canCool) = ModelStateText();
        var current = models.Contains(settings.Model ?? "") ? settings.Model : resolvedModel;
        return
        [
            new(T("Редактор для выделенного", "Editor for Selection") + "\t" + Display(settings.EditorHotKey),
                () => OpenEditor(foreground.Last)),
            new(T("Исправить сразу", "Fix Instantly") + "\t" + Display(settings.QuickHotKey), () => _ = QuickFix(foreground.Last)),
            MenuItem.Separator,
            new(state, Enabled: false),
            new(T("Прогреть модель", "Warm Up Model"), Warm, Enabled: canWarm),
            new(T("Выгрузить модель из памяти", "Unload Model from Memory"), Cool, Enabled: canCool),
            MenuItem.Separator,
            new(T("Модель", "Model"), Enabled: models.Count > 0, Submenu: models.Count == 0 ? [] :
                models.Select(m => new MenuItem(m, () => PickModel(m), Checked: m == current)).ToList()),
            new(T("Запускать при входе", "Open at Login"), () => AutoStart.Enabled = !AutoStart.Enabled, Checked: AutoStart.Enabled),
            new(T("Открыть журнал", "Open Log"), OpenLog),
            MenuItem.Separator,
            new(T("Выход", "Quit"), Quit),
        ];
    }

    void PickModel(string id)
    {
        settings.Model = id;
        settings.Save();
        Log.Write("выбрана модель " + id);
        if (settings.Prewarm) Warm();
    }

    static void OpenLog()
    {
        var path = Path.Combine(AppPaths.Data, "log.txt");
        if (File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    void Quit()
    {
        hotKeys.UnregisterAll();
        tray.Dispose();
        foreground.Dispose();
        app.Exit();
    }

    // прогрев и охлаждение модели

    enum ModelState { Unknown, Loaded, Unloaded, Warming, Cooling, Offline }
    ModelState modelState = ModelState.Unknown;
    long? loadedBytes;
    List<string> models = [];
    string? resolvedModel;

    (string Text, bool CanWarm, bool CanCool) ModelStateText() => modelState switch
    {
        ModelState.Loaded => (T("Модель: в памяти, готова", "Model: loaded, ready")
                              + (loadedBytes is { } b ? T($" · {b / 1e9:F1} ГБ", $" · {b / 1e9:F1} GB") : ""), false, true),
        ModelState.Unloaded => (T("Модель: выгружена — первая правка ~15 с", "Model: unloaded — first edit takes ~15 s"), true, false),
        ModelState.Warming => (T("Модель: прогреваю…", "Model: warming up…"), false, false),
        ModelState.Cooling => (T("Модель: выгружаю…", "Model: unloading…"), false, false),
        ModelState.Offline => (T("Модель: LM Studio не отвечает", "Model: LM Studio is not responding"), true, false),
        _ => (T("Модель: проверяю…", "Model: checking…"), true, false),
    };

    void SetState(ModelState s)
    {
        modelState = s;
        tray.Tooltip = "FairCopy — " + ModelStateText().Text.Split(": ", 2)[^1];
    }

    async void Warm()
    {
        if (modelState == ModelState.Warming) return;
        SetState(ModelState.Warming);
        tray.Busy = true;
        await LLMClient.Shared.PrewarmAsync();
        tray.Busy = working;
        await RefreshModelState();
    }

    async void Cool()
    {
        SetState(ModelState.Cooling);
        await LLMClient.Shared.UnloadAsync();
        await RefreshModelState();
    }

    async Task RefreshModelState()
    {
        try { models = await LLMClient.Shared.ListModelsAsync(); resolvedModel = await LLMClient.Shared.ResolveModelAsync(); }
        catch { models = []; resolvedModel = null; }
        if (modelState is ModelState.Warming or ModelState.Cooling) return;
        var loaded = await LLMClient.Shared.LoadedModelsAsync();
        if (loaded is null) { SetState(ModelState.Offline); return; }
        var m = loaded.FirstOrDefault(x => resolvedModel is null || x.Identifier == resolvedModel);
        loadedBytes = m?.SizeBytes;
        SetState(m is null ? ModelState.Unloaded : ModelState.Loaded);
    }

    void PrewarmIfEnabled()
    {
        if (settings.Prewarm) Warm();
    }

    // действия

    /// Окно редактора для выделенного (или всего поля) текста.
    /// fromMenu — окно, активное до щелчка по значку; с хоткея — текущее активное окно.
    async void OpenEditor(TextTarget? fromMenu)
    {
        if (editor?.IsShown == true && fromMenu is null && TextBridge.Foreground() is null) return; // хоткей в самом окне
        if (working) { Keyboard.Beep(); return; }
        working = true;
        try
        {
            if (fromMenu is not null) TextBridge.Activate(fromMenu);
            var target = fromMenu ?? TextBridge.Foreground();
            if (target is null) { Keyboard.Beep(); return; }
            Log.Write($"редактор для {target.ExeName}");
            // окно — у строки с текстом, а не у мыши: хоткей жмут с клавиатуры, мышь может быть где угодно
            var place = await TextBridge.FocusedTextRect();
            var text = await TextBridge.GrabText();
            if (text is null) { Keyboard.Beep(); return; }
            editorTarget = target;
            EnsureEditor();
            editorModel.Start(text, target.ExeName);
            var (mx, my) = TextBridge.CursorPosition();
            editor!.ShowAt(place ?? (mx, my, 0, 0));
        }
        catch (Exception e)
        {
            Log.Write("редактор: " + e);
            tray.Notify("FairCopy", e.Message, error: true);
        }
        finally { working = false; }
    }

    async void ApplyEditor(string text)
    {
        editorModel.RememberForApp(editorTarget?.DisplayName);
        editorModel.Cancel();
        var target = editorTarget;
        // сначала возвращаем фокус исходному окну (пока мы активны, Windows это разрешает), потом прячемся
        if (target is not null) TextBridge.Activate(target);
        editor?.HideWindow();
        if (target is not null) await TextBridge.Paste(text, target);
    }

    void CloseEditor()
    {
        editorModel.Cancel();
        if (editorTarget is not null) TextBridge.Activate(editorTarget);
        editor?.HideWindow();
    }

    /// Исправить выделенное (или всё поле) и сразу вставить результат.
    /// fromMenu — окно, активное до щелчка по значку; с хоткея — текущее активное окно.
    async Task QuickFix(TextTarget? fromMenu)
    {
        if (working) { Keyboard.Beep(); return; }
        working = true;
        try
        {
            if (fromMenu is not null) TextBridge.Activate(fromMenu);
            var target = fromMenu ?? TextBridge.Foreground();
            if (target is null) { Keyboard.Beep(); return; }
            Log.Write($"быстрая замена в {target.ExeName}");
            var text = await TextBridge.GrabText();
            if (text is null) { Keyboard.Beep(); return; }
            tray.Busy = true;
            // берём стиль, запомненный для этого приложения (перевод без окна не делаем — это сюрприз)
            var pref = settings.RememberPerApp ? settings.AppPrefs.GetValueOrDefault(target.ExeName) : null;
            var style = pref?.EditMode == EditMode.Style ? StyleStore.Shared.Find(pref.StyleID) : null;
            var msgs = Prompts.Messages(style is null ? EditMode.Fix : EditMode.Style, style, "", text,
                                        dictionary: settings.Dictionary);
            var sw = Stopwatch.StartNew();
            var fixedText = await LLMClient.Shared.CompleteAsync(msgs);
            Log.Write($"модель ответила за {sw.Elapsed.TotalSeconds:F1} с ({fixedText.Length} симв.)");
            if (fixedText.Length == 0) { Keyboard.Beep(); return; }
            await TextBridge.Paste(fixedText, target);
            if (modelState != ModelState.Loaded) _ = RefreshModelState();
        }
        catch (Exception e)
        {
            Log.Write("быстрая замена: " + e);
            Keyboard.Beep();
            tray.Notify("FairCopy", e.Message, error: true);
        }
        finally
        {
            working = false;
            tray.Busy = false;
        }
    }
}
