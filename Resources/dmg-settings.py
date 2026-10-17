# dmgbuild settings for the drag-to-Applications disk image (`make dmg`).
# Icon positions must match the layout drawn by Resources/DMGBackground.swift.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = defines["background"]

# The height includes the ~28 pt title bar, so the whole 640×420 background stays visible.
window_rect = ((200, 140), (640, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (170, 200),
    "Applications": (470, 200),
}
