#!/bin/zsh
# Сборка и запуск на домашнем ПК. Главная копия файлов — на Mac (~/Projects/FairCopy/windows),
# на ПК (I:\FairCopy: windows\ и общий shared\) — только зеркало для сборки: правки там затираются следующим sync.
#
#   tools/pc.sh sync               — залить исходники на ПК
#   tools/pc.sh build              — sync + dotnet build всего решения
#   tools/pc.sh cli <аргументы>    — запустить faircopy-cli на ПК (после build)
#   tools/pc.sh dump               — build + сверка --dump-prompts с эталоном macOS (ru и en)
#   tools/pc.sh run                — build + перезапуск FairCopy.exe в сеансе пользователя (с окнами и треем)
#   tools/pc.sh stop               — закрыть FairCopy.exe
#   tools/pc.sh shot               — FairCopy --panel [fix|style|translate] + скриншот, без нажатий клавиш → /tmp/faircopy-shot.png
#   tools/pc.sh log                — журнал приложения (%APPDATA%\FairCopy\log.txt)
#   tools/pc.sh ps '<код PowerShell>' — выполнить PowerShell на ПК (через файл: без мучений с кавычками cmd)
#   tools/pc.sh sh '<команда cmd>' — произвольная команда на ПК в папке проекта
set -e
cd "${0:A:h}/.."
PC_ROOT='I:\FairCopy'
PC_DIR='I:\FairCopy\windows'
# адрес ПК и ключ ssh — в tools/pc.local (не в git): PC_HOST=user@host, PC_KEY=~/.ssh/key
[[ -f tools/pc.local ]] && source tools/pc.local
: ${PC_HOST:?"задай PC_HOST (и PC_KEY) в tools/pc.local"}
PC_KEY=${PC_KEY:-~/.ssh/id_ed25519}
pc() { ssh -i $PC_KEY -o ConnectTimeout=8 $PC_HOST "$@"; }
pcget() { scp -q -i $PC_KEY "$PC_HOST:$1" "$2"; }   # файл с ПК (путь от домашней папки)
pcput() { scp -q -i $PC_KEY "$1" "$PC_HOST:$2"; }

sync() {
  # tar есть и в Windows (bsdtar); bin/obj не трогаем, чтобы сборка оставалась инкрементальной
  # из корня репозитория: Windows-версия и общие с Mac промпты и стили (shared/)
  (cd .. && COPYFILE_DISABLE=1 tar czf - --exclude bin --exclude obj --exclude .DS_Store --exclude CLAUDE.md \
    --exclude pc.local windows shared) | pc "(if not exist $PC_ROOT mkdir $PC_ROOT) & tar xzf - -C $PC_ROOT"
}

build() {
  sync
  pc "cd /d $PC_DIR && dotnet build FairCopy.slnx -nologo -v q -clp:NoSummary;ErrorsOnly"
}

app_exe="$PC_DIR\\src\\FairCopy.App\\bin\\Debug\\net10.0-windows10.0.19041.0\\win-x64\\FairCopy.exe"

# процессы, запущенные из ssh, живут в сеансе 0 без рабочего стола; задача планировщика с /it
# запускает программу в сеансе вошедшего пользователя
run_interactive() {
  pc "schtasks /create /tn FairCopyRun /tr \"$1\" /sc once /st 23:59 /it /f >nul 2>&1 & schtasks /run /tn FairCopyRun >nul & schtasks /delete /tn FairCopyRun /f >nul"
}

stop() { pc 'taskkill /im FairCopy.exe /f >nul 2>&1 & exit 0'; }

cli_cmd="cd /d $PC_DIR && src\\FairCopy.Cli\\bin\\Debug\\net10.0\\faircopy-cli.exe"

case "$1" in
  sync) sync ;;
  build) build ;;
  cli) shift; pc "$cli_cmd $*" ;;
  dump)
    build
    for l in ru en; do
      pc "set FAIRCOPY_LANG=$l&& $cli_cmd --dump-prompts" > /tmp/faircopy-dump-$l.txt
      if cmp -s /tmp/faircopy-dump-$l.txt tests/reference/dump-$l.txt; then echo "$l: совпадает с macOS"
      else echo "$l: РАСХОДИТСЯ"; diff tests/reference/dump-$l.txt /tmp/faircopy-dump-$l.txt | head -20; fi
    done ;;
  run) stop; build; run_interactive "$app_exe"; sleep 4; pc 'tasklist /fi "imagename eq FairCopy.exe" | find /i "FairCopy"' ;;
  stop) stop ;;
  shot)
    # FairCopy перезапускается с --panel [режим] и сам открывает редактор; скрипт только фотографирует экран
    stop; build
    run_interactive "$app_exe --panel ${2:-fix}"
    sleep ${3:-14}
    pc 'del "%TEMP%\\faircopy-shot.png" 2>nul & exit 0'
    run_interactive "powershell -NoProfile -ExecutionPolicy Bypass -File $PC_DIR\\tools\\shot-editor.ps1"
    sleep 5
    pcget AppData/Local/Temp/faircopy-shot.png /tmp/faircopy-shot.png && echo /tmp/faircopy-shot.png ;;
  log) pc 'type "%APPDATA%\\FairCopy\\log.txt"' ;;
  ps)
    shift
    f=$(mktemp -t fcps).ps1
    { printf '\xef\xbb\xbf[Console]::OutputEncoding = [Text.Encoding]::UTF8\n'; print -r -- "$*"; } > $f
    pcput $f fc-tmp.ps1 && pc 'powershell -NoProfile -ExecutionPolicy Bypass -File fc-tmp.ps1 & del fc-tmp.ps1'
    rm -f $f ;;
  sh) shift; pc "cd /d $PC_DIR && $*" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
