"""Finder layout for the drag-to-Applications installer."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
hide = [".background.tiff"]
# Do not use hide_extensions: SetFile adds FinderInfo to the signed app,
# causing strict codesign verification to reject the bundle.

format = "UDZO"
filesystem = "HFS+"
background = defines["background"]
# Coordinates match the point canvas in dmg-background.swift.
# Finder's 32-point title bar is outside the artwork's 460-point content.
window_rect = ((200, 200), (720, 492))
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
text_size = 14
label_pos = "bottom"
icon_locations = {"Meterlark.app": (180, 278), "Applications": (540, 278)}
