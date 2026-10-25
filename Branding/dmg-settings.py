# Настройки dmgbuild для установочного образа FairCopy (см. release.sh).
# Значения передаются через -D: app (путь к .app), background (путь к background.png).
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"  # lzfse: маленький и быстро открывается
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # рядом лежит background@2x.png — dmgbuild соберёт HiDPI-фон
# высота окна включает заголовок (~28 pt); фон 420 pt — важное держим выше 380 на случай панели вкладок
window_rect = ((200, 160), (660, 448))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {app_name: (165, 225), "Applications": (430, 225)}
hide_extensions = [app_name]
