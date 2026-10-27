# Проверка быстрой замены на Блокноте. Запускать в сеансе пользователя (tools/pc.sh selftest),
# FairCopy должен быть запущен. Результат — в %TEMP%\faircopy-selftest.txt.
#   1) текст выделен      — FairCopy берёт выделение через UI Automation;
#   2) ничего не выделено — FairCopy сам делает Ctrl+A, Ctrl+C.
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
$out = Join-Path $env:TEMP 'faircopy-selftest.txt'
Set-Content $out '' -Encoding UTF8
function Say($s) { Add-Content $out $s -Encoding UTF8 }

$text = 'короче я щас не смогу прийти потомучто машина сломалась может завтра норм будет'
$saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue

$p = Start-Process notepad -PassThru
Start-Sleep 2
$shell = New-Object -ComObject WScript.Shell
$null = $shell.AppActivate('Блокнот') -or $shell.AppActivate('Notepad')
Start-Sleep -Milliseconds 500

function DocumentText {
    $root = [Windows.Automation.AutomationElement]::FocusedElement
    $pat = $null
    if ($root.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$pat)) { return $pat.DocumentRange.GetText(-1) }
    return '(нет TextPattern)'
}

function Case($name, $select) {
    Set-Clipboard $text
    [Windows.Forms.SendKeys]::SendWait('^a{DEL}^v')
    Start-Sleep -Milliseconds 400
    if ($select) { [Windows.Forms.SendKeys]::SendWait('^a') } else { [Windows.Forms.SendKeys]::SendWait('^{END}') }
    Start-Sleep -Milliseconds 300
    $t0 = Get-Date
    [Windows.Forms.SendKeys]::SendWait('^%+r')
    # ждём, пока текст в окне сменится (до 40 с: первая правка грузит модель)
    do { Start-Sleep -Milliseconds 500; $now = DocumentText } while ($now.Trim() -eq $text -and ((Get-Date) - $t0).TotalSeconds -lt 40)
    Start-Sleep -Milliseconds 700
    Say "$name [$([int]((Get-Date) - $t0).TotalSeconds) с]: $(DocumentText)"
}

Case 'выделено' $true
Case 'без выделения' $false

# убираем за собой: пустую вкладку Блокнот закрывает без вопроса о сохранении
[Windows.Forms.SendKeys]::SendWait('^a{DEL}^w')
Start-Sleep 1
if (-not $p.HasExited) { Stop-Process $p -ErrorAction SilentlyContinue }
if ($saved) { Set-Clipboard $saved }
Say 'готово'
