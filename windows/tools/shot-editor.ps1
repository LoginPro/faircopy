# Только снимок экрана — никаких нажатий клавиш (в RDP-сеансе SendKeys теряет Ctrl и печатает буквы
# в чужие окна). Окно редактора открывает сам FairCopy по ключу --panel (tools/pc.sh shot).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# без этого при масштабе 150% снимается только часть экрана в логических координатах
Add-Type -Namespace W -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[W.Dpi]::SetProcessDPIAware() | Out-Null
$b = [Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
[Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save((Join-Path $env:TEMP 'faircopy-shot.png'), [Drawing.Imaging.ImageFormat]::Png)
