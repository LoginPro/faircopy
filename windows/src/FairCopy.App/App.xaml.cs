using Microsoft.UI.Xaml;

namespace FairCopy.App;

/// Приложение без главного окна: живёт в трее (как accessory-приложение на macOS).
public partial class App : Application
{
    static Mutex? single;
    Controller? controller;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => Log.Write("необработанная ошибка: " + e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // второй экземпляр не нужен: хоткеи и значок уже у первого
        single = new Mutex(true, @"Local\FairCopy", out bool first);
        if (!first) { Exit(); return; }
        // окон нет вовсе, и закрытие окна настроек не должно завершать приложение
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        controller = new Controller(this);
        controller.Start();
    }
}
