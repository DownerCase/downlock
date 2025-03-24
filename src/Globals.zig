const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlExt = wayland.client.ext;
const wlZwlr = wayland.client.zwlr;

display: *wl.Display,
compositor: *wl.Compositor,
shm: *wl.Shm,
seat: *wl.Seat,
sessionLockManager: *wlExt.SessionLockManagerV1,
screencopyManager: *wlZwlr.ScreencopyManagerV1,
viewporter: *wayland.client.wp.Viewporter,
