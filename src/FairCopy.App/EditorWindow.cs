using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Graphics;
using Windows.System;
using static FairCopy.Lang;

namespace FairCopy.App;

/// Окно редактора: плавающее акриловое окно без заголовка у строки с курсором (аналог EditorPanel).
/// Интерфейс собран в коде и обновляется по EditorModel.Changed — без пересоздания элементов,
/// чтобы не терять фокус и выделение в полях ввода.
sealed class EditorWindow : Window
{
    const double PanelWidth = 460;

    readonly EditorModel model;
    readonly IntPtr hwnd;
    public event Action<string>? Applied;
    public event Action? Dismissed;

    // элементы окна
    // StackPanel, а не Grid: у скрытых строк Grid отступ RowSpacing остаётся и даёт пустые полосы
    readonly StackPanel root = new() { Padding = new Thickness(18, 14, 18, 18), Spacing = 12 };
    readonly ProgressRing progress = new() { Width = 16, Height = 16, IsActive = false };
    readonly TextBlock stats = new() { Opacity = 0.55, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly SelectorBar modes = new();
    readonly FlowPanel styleChips = new() { Spacing = 6, LineSpacing = 6 };
    readonly ComboBox language = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly Grid customRow = new() { ColumnSpacing = 8 };
    readonly TextBox customBox = new();
    readonly Button customSave = new();
    readonly TextBlock originalShort = new() { MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0.65 };
    readonly TextBlock originalFull = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.65, IsTextSelectionEnabled = true };
    readonly ScrollViewer originalScroll = new() { MaxHeight = 160 };
    readonly FontIcon originalChevron = new() { Glyph = "", FontSize = 12 };
    readonly Button editButton = new() { Padding = new Thickness(8, 2, 8, 2), FontSize = 12 };
    readonly StackPanel errorPanel = new() { Spacing = 8 };
    readonly TextBlock errorText = new() { TextWrapping = TextWrapping.Wrap };
    readonly StackPanel thinking = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    readonly TextBox editBox = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    readonly RichTextBlock resultText = new() { IsTextSelectionEnabled = true };
    readonly ScrollViewer resultScroll = new();
    readonly StackPanel hint = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    readonly TextBlock hintText = new() { TextWrapping = TextWrapping.Wrap, FontSize = 13 };
    readonly Button apply = new() { HorizontalAlignment = HorizontalAlignment.Stretch, Height = 36 };
    readonly TextBlock applyKey = new() { Opacity = 0.7 };
    readonly Button rerun = IconButton("", T("Ещё раз (Ctrl+R)", "Again (Ctrl+R)"));
    readonly Button copy = IconButton("", T("Скопировать", "Copy"));

    /// Какая правка под каким фрагментом текста — для подсказок при наведении.
    readonly Dictionary<Run, string> runKeys = [];
    bool updating;
    string chipsSignature = "", resultSignature = "";

    // положение: под строкой текста (верхний край фиксирован) или над ней (нижний)
    bool anchorTop = true;
    int anchorY, left;
    RectInt32 work;
    double scale = 1;

    public EditorWindow(EditorModel model)
    {
        this.model = model;
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Title = "FairCopy";
        SystemBackdrop = new Microsoft.UI.Xaml.Media.DesktopAcrylicBackdrop();

        var presenter = OverlappedPresenter.CreateForToolWindow();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "FairCopy.ico"));
        WindowNative.RoundCorners(hwnd);
        // Alt+F4 — как «Закрыть»: окно прячем, а не уничтожаем
        AppWindow.Closing += (_, e) => { e.Cancel = true; Dismissed?.Invoke(); };

        Build();
        Content = root;
        root.PreviewKeyDown += OnKey;
        model.Changed += Update;
    }

    static Button IconButton(string glyph, string tip)
    {
        var b = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Width = 36, Height = 36, Padding = new Thickness(0) };
        ToolTipService.SetToolTip(b, tip);
        return b;
    }

    static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    void Build()
    {
        // шапка: бренд тихо, главное в окне — текст; за шапку окно можно перетащить
        var header = new Grid { ColumnSpacing = 8, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var brand = new TextBlock { Text = "FairCopy", FontWeight = FontWeights.SemiBold, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center };
        var close = IconButton("", T("Закрыть (Esc)", "Close (Esc)"));
        close.Width = close.Height = 30;
        close.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        close.BorderThickness = new Thickness(0);
        close.Click += (_, _) => Dismissed?.Invoke();
        Grid.SetColumn(progress, 2);
        Grid.SetColumn(stats, 3);
        Grid.SetColumn(close, 4);
        header.Children.Add(brand);
        header.Children.Add(progress);
        header.Children.Add(stats);
        header.Children.Add(close);
        header.PointerPressed += (_, e) =>
        {
            if (e.OriginalSource is not Button && e.GetCurrentPoint(header).Properties.IsLeftButtonPressed) WindowNative.BeginDrag(hwnd);
        };

        foreach (var m in new[] { EditMode.Fix, EditMode.Style, EditMode.Translate })
            modes.Items.Add(new SelectorBarItem { Text = m.Title(), Tag = m });
        modes.SelectionChanged += (_, _) =>
        {
            if (!updating && modes.SelectedItem?.Tag is EditMode m) model.Mode = m;
        };

        foreach (var l in Prompts.Languages) language.Items.Add(l);
        language.SelectionChanged += (_, _) =>
        {
            if (!updating && language.SelectedItem is string l) model.Language = l;
        };

        customBox.PlaceholderText = T("Опиши стиль: «как пират», «с сарказмом»… и нажми Enter",
                                      "Describe a style: “like a pirate”, “sarcastic”… and press Enter");
        customBox.TextChanged += (_, _) =>
        {
            if (updating) return;
            model.CustomStyle = customBox.Text;
            customSave.IsEnabled = customBox.Text.Trim().Length > 0;
        };
        customSave.Content = T("Сохранить", "Save");
        ToolTipService.SetToolTip(customSave, T("Сохранить как постоянный стиль", "Save as a permanent style"));
        customSave.Click += (_, _) => model.SaveCustomAsStyle();
        customRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        customRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(customSave, 1);
        customRow.Children.Add(customBox);
        customRow.Children.Add(customSave);

        // карточка «Оригинал / Результат»
        var originalHeader = new Grid();
        originalHeader.Children.Add(new TextBlock { Text = T("Оригинал", "Original"), FontWeight = FontWeights.SemiBold });
        originalChevron.HorizontalAlignment = HorizontalAlignment.Right;
        originalHeader.Children.Add(originalChevron);
        var originalButton = new Button
        {
            Content = originalHeader, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
        };
        originalButton.Click += (_, _) => { model.ShowOriginal = !model.ShowOriginal; Update(); };
        originalScroll.Content = originalFull;

        var resultHeader = new Grid();
        resultHeader.Children.Add(new TextBlock { Text = T("Результат", "Result"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        editButton.HorizontalAlignment = HorizontalAlignment.Right;
        editButton.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        editButton.BorderThickness = new Thickness(0);
        editButton.Click += (_, _) =>
        {
            if (model.Editing) model.FinishEditing();
            else { editBox.Text = model.Result; model.Editing = true; editBox.Focus(FocusState.Programmatic); }
        };
        resultHeader.Children.Add(editButton);

        errorText.Foreground = Res("SystemFillColorCriticalBrush");
        var retry = new Button { Content = T("Ещё раз", "Try Again") };
        retry.Click += (_, _) => model.Run();
        errorPanel.Children.Add(errorText);
        errorPanel.Children.Add(retry);

        thinking.Children.Add(new ProgressRing { Width = 14, Height = 14, IsActive = true });
        thinking.Children.Add(new TextBlock { Text = T("Думаю…", "Thinking…"), Opacity = 0.65 });

        editBox.TextChanged += (_, _) => { if (!updating) model.SetResult(editBox.Text); };

        resultScroll.Content = resultText;
        resultText.PointerMoved += (_, e) => model.Hover(KeyAt(e));
        resultText.PointerExited += (_, _) => model.Hover(null);

        hint.Children.Add(new TextBlock { Text = "💡" });
        hint.Children.Add(hintText);

        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(originalButton);
        card.Children.Add(originalShort);
        card.Children.Add(originalScroll);
        card.Children.Add(new Border { Height = 1, Background = Res("DividerStrokeColorDefaultBrush"), Margin = new Thickness(0, 4, 0, 4) });
        card.Children.Add(resultHeader);
        card.Children.Add(errorPanel);
        card.Children.Add(thinking);
        card.Children.Add(editBox);
        card.Children.Add(resultScroll);
        card.Children.Add(hint);
        var cardBorder = new Border
        {
            Child = card, Padding = new Thickness(12), CornerRadius = new CornerRadius(8),
            Background = Res("CardBackgroundFillColorDefaultBrush"), BorderBrush = Res("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };

        // кнопки
        var applyLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        applyLabel.Children.Add(new TextBlock { Text = T("Применить", "Apply") });
        applyLabel.Children.Add(applyKey);
        apply.Content = applyLabel;
        apply.Style = (Microsoft.UI.Xaml.Style)Application.Current.Resources["AccentButtonStyle"];
        apply.Click += (_, _) => Apply();
        rerun.Click += (_, _) => model.Run();
        copy.Click += (_, _) =>
        {
            var p = new DataPackage();
            p.SetText(model.Result);
            Clipboard.SetContent(p);
        };
        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(rerun, 1);
        Grid.SetColumn(copy, 2);
        buttons.Children.Add(apply);
        buttons.Children.Add(rerun);
        buttons.Children.Add(copy);

        foreach (var row in new UIElement[] { header, modes, styleChips, language, customRow, cardBorder, buttons })
            root.Children.Add(row);
    }

    // обновление по модели

    void Update()
    {
        updating = true;
        try
        {
            progress.IsActive = model.Running;
            stats.Text = model.Stats;
            modes.SelectedItem = modes.Items.First(i => (EditMode)i.Tag == model.Mode);

            bool style = model.Mode == EditMode.Style, translate = model.Mode == EditMode.Translate;
            styleChips.Visibility = style || translate ? Visibility.Visible : Visibility.Collapsed;
            language.Visibility = translate ? Visibility.Visible : Visibility.Collapsed;
            if (translate && (language.SelectedItem as string) != model.Language) language.SelectedItem = model.Language;
            bool custom = (style && model.StyleID == Style.CustomID) || (translate && model.TranslateStyleID == Style.CustomID);
            customRow.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
            if (customBox.Text != model.CustomStyle) customBox.Text = model.CustomStyle;
            customSave.IsEnabled = model.CustomStyle.Trim().Length > 0;
            UpdateChips();

            originalShort.Text = model.Original.ReplaceLineEndings(" ");
            originalFull.Text = model.Original;
            originalShort.Visibility = model.ShowOriginal ? Visibility.Collapsed : Visibility.Visible;
            originalScroll.Visibility = model.ShowOriginal ? Visibility.Visible : Visibility.Collapsed;
            originalChevron.Glyph = model.ShowOriginal ? "" : "";

            bool hasResult = !model.Running && model.Error is null && model.Result.Length > 0;
            editButton.Visibility = hasResult ? Visibility.Visible : Visibility.Collapsed;
            editButton.Content = model.Editing ? "✓ " + T("Готово", "Done") : "✎ " + T("Изменить", "Edit");
            ToolTipService.SetToolTip(editButton, model.Editing ? T("Закончить правку", "Finish editing")
                                                               : T("Поправить результат вручную", "Edit the result by hand"));

            errorPanel.Visibility = model.Error is null ? Visibility.Collapsed : Visibility.Visible;
            errorText.Text = "⚠ " + model.Error;
            thinking.Visibility = model.Error is null && model.Result.Length == 0 && model.Running ? Visibility.Visible : Visibility.Collapsed;
            editBox.Visibility = model.Editing && model.Error is null ? Visibility.Visible : Visibility.Collapsed;
            resultScroll.Visibility = !model.Editing && model.Error is null && model.Result.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            editBox.MaxHeight = resultScroll.MaxHeight;
            UpdateResult();

            var h = model.HintText;
            hint.Visibility = h.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            hintText.Text = h;
            hintText.Opacity = model.HoverKey is null ? 0.65 : 1;

            apply.IsEnabled = !model.Running && model.Result.Length > 0;
            applyKey.Text = model.Editing ? "Ctrl+Enter" : "↵";
            copy.IsEnabled = model.Result.Length > 0;
        }
        finally { updating = false; }
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, Fit);
    }

    /// Капсулы стилей пересобираем, только когда меняется сам набор или выбор, — не на каждый токен ответа.
    void UpdateChips()
    {
        if (model.Mode == EditMode.Fix) return;
        bool translate = model.Mode == EditMode.Translate;
        string? selected = translate ? model.TranslateStyleID : model.StyleID;
        var styles = StyleStore.Shared.Styles;
        var signature = $"{model.Mode}|{selected}|{string.Join(",", styles.Select(s => s.Id + s.Emoji + s.Name))}";
        if (signature == chipsSignature) return;
        chipsSignature = signature;
        styleChips.Children.Clear();
        void Chip(string? id, string emoji, string title)
        {
            var b = new ToggleButton { Content = $"{emoji} {title}", IsChecked = selected == id, CornerRadius = new CornerRadius(14),
                                       Padding = new Thickness(11, 4, 11, 5), FontSize = 13 };
            b.Click += (_, _) =>
            {
                if (translate) model.TranslateStyleID = id; else model.StyleID = id ?? Style.CustomID;
                chipsSignature = ""; // ToggleButton уже переключился сам — пересобираем по модели
                Update();
            };
            styleChips.Children.Add(b);
        }
        if (translate) Chip(null, "🚫", T("Без стиля", "No Style"));
        foreach (var s in styles) Chip(s.Id, s.Emoji, s.Name);
        Chip(Style.CustomID, "✍️", T("Свой стиль", "Custom"));
    }

    /// Результат с подсветкой правок, как в Telegram: удалённое — красным зачёркнутым, добавленное — подчёркнутым.
    void UpdateResult()
    {
        var signature = $"{model.Result.Length}|{model.Result.GetHashCode()}|{model.Segments.Count}|{model.HoverKey}";
        if (signature == resultSignature) return;
        resultSignature = signature;
        runKeys.Clear();
        var p = new Paragraph();
        if (model.Segments.Count == 0)
            p.Inlines.Add(new Run { Text = model.Result });
        else
        {
            var removed = Res("SystemFillColorCriticalBrush");
            var added = Res("AccentTextFillColorPrimaryBrush");
            foreach (var seg in model.Segments)
            {
                if (seg.Same is { } same) { p.Inlines.Add(new Run { Text = same }); continue; }
                bool hovered = model.HoverKey == seg.Key;
                if (seg.Removed.Length > 0)
                {
                    var r = new Run { Text = seg.Removed, Foreground = removed, TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough };
                    if (hovered) r.FontWeight = FontWeights.SemiBold;
                    runKeys[r] = seg.Key;
                    p.Inlines.Add(r);
                }
                if (seg.Added.Length > 0)
                {
                    var r = new Run { Text = seg.Added, Foreground = added, TextDecorations = Windows.UI.Text.TextDecorations.Underline };
                    if (hovered) r.FontWeight = FontWeights.SemiBold;
                    runKeys[r] = seg.Key;
                    p.Inlines.Add(r);
                }
            }
        }
        resultText.Blocks.Clear();
        resultText.Blocks.Add(p);
    }

    string? KeyAt(PointerRoutedEventArgs e)
    {
        try
        {
            var pos = resultText.GetPositionFromPoint(e.GetCurrentPoint(resultText).Position);
            return pos?.Parent is Run r && runKeys.TryGetValue(r, out var key) ? key : null;
        }
        catch { return null; }
    }

    // клавиатура: Esc — закрыть, Enter — применить (при ручной правке — Ctrl+Enter), Ctrl+R — ещё раз

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        bool ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                Dismissed?.Invoke();
                break;
            case VirtualKey.Enter when ReferenceEquals(e.OriginalSource, customBox):
                e.Handled = true;
                model.Run();
                break;
            case VirtualKey.Enter when ctrl || (!model.Editing && e.OriginalSource is not ComboBox):
                e.Handled = true;
                Apply();
                break;
            case VirtualKey.R when ctrl:
                e.Handled = true;
                model.Run();
                break;
        }
    }

    void Apply()
    {
        if (model.Running || model.Result.Length == 0) return;
        if (model.Editing) model.SetResult(editBox.Text);
        Applied?.Invoke(model.Result);
    }

    // положение и размер

    /// target — строка с текстовым курсором (физические пиксели) или точка мыши.
    public void ShowAt((int X, int Y, int Width, int Height) target)
    {
        scale = WindowNative.ScaleAt(target.X + target.Width / 2, target.Y + target.Height / 2);
        work = DisplayArea.GetFromPoint(new PointInt32(target.X, target.Y), DisplayAreaFallback.Nearest).WorkArea;
        // ~470 DIP занимают шапка, режимы, стили, оригинал, подсказка и кнопки — остальное отдаём результату
        double maxResult = Math.Max(140, work.Height / scale - 16 - 470);
        resultScroll.MaxHeight = maxResult;
        editBox.MaxHeight = maxResult;

        // под строкой, если там хватает места на типичное окно, иначе над ней (как поле ввода
        // мессенджера внизу экрана — окно встаёт над ним и не закрывает текст)
        int roomBelow = work.Y + work.Height - (target.Y + target.Height);
        anchorTop = roomBelow >= 420 * scale;
        anchorY = anchorTop ? target.Y + target.Height + (int)(10 * scale) : target.Y - (int)(10 * scale);
        int width = (int)(PanelWidth * scale);
        left = Math.Clamp(target.X - (int)(24 * scale), work.X + (int)(8 * scale), work.X + work.Width - width - (int)(8 * scale));

        Update();
        Fit();
        AppWindow.Show();
        Activate();
        apply.Focus(FocusState.Programmatic);
    }

    /// Подгоняет высоту окна под содержимое, держа якорный край на месте.
    void Fit()
    {
        if (work.Height == 0) return;
        root.Measure(new Size(PanelWidth, double.PositiveInfinity));
        int width = (int)(PanelWidth * scale);
        int height = (int)Math.Ceiling(root.DesiredSize.Height * scale);
        height = Math.Min(height, work.Height - (int)(16 * scale));
        int top = anchorTop ? anchorY : anchorY - height;
        // не влезает — сдвигаем внутрь экрана, а не обрезаем
        top = Math.Clamp(top, work.Y + (int)(8 * scale), work.Y + work.Height - height - (int)(8 * scale));
        // ResizeClient у окна без заголовка прибавляет высоту невидимого заголовка — задаём внешний
        // размер с поправкой на реальную разницу между окном и клиентской областью (рамка)
        int dw = AppWindow.Size.Width - AppWindow.ClientSize.Width, dh = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        AppWindow.MoveAndResize(new RectInt32(left, top, width + dw, height + dh));
    }

    public void HideWindow() => AppWindow.Hide();

    public bool IsShown => AppWindow.IsVisible;
}
