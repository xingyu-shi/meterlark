"""Finder layout for the drag-to-Applications installer."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
# Do not use hide_extensions: SetFile adds FinderInfo to the signed app,
# causing strict codesign verification to reject the bundle.

format = "UDZO"
filesystem = "HFS+"
background = "builtin-arrow"
window_rect = ((200, 200), (640, 280))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 128
text_size = 16
label_pos = "bottom"
icon_locations = {"Meterlark.app": (140, 120), "Applications": (500, 120)}
