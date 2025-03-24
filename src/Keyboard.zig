const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;

const xkb = @import("xkb.zig");

pub const KeyEvent = struct {
    serial: u32,
    time: u32,
    keysym: xkb.KeySym,
    keyUtf8: []const u8,
    state: wl.Keyboard.KeyState,
};

keyboard: ?*wl.Keyboard = null,
xkb_context: ?*xkb.Context = null,
xkb_state: ?*xkb.State = null,
xkb_keymap: ?*xkb.Keymap = null,

callback_fn: *const fn (keyboard: *Self, key: KeyEvent) void,

const Self = @This();

pub fn deinit(self: *Self) void {
    if (self.keyboard) |kb| kb.release();
    if (self.xkb_state) |sstate| sstate.unref();
    if (self.xkb_keymap) |skeymap| skeymap.unref();
    if (self.xkb_context) |ctx| ctx.unref();
}

pub fn attachSeat(self: *Self, seat: *wl.Seat) void {
    seat.setListener(*Self, Self.seatListener, self);
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Self) void {
    switch (event) {
        .name => |_| {},
        .capabilities => |evt| {
            if (evt.capabilities.keyboard) {
                // Use keyboard
                const kb = seat.getKeyboard() catch return;
                if (self.xkb_context == null) {
                    self.xkb_context = xkb.Context.new(xkb.Context.Flags.no_flags);
                }
                if (self.keyboard == null) {
                    self.keyboard = kb;
                    kb.setListener(*Self, listener, self);
                }
            } else {
                // Release keyboard
                if (self.keyboard) |kb| kb.release();
                self.keyboard = null;
            }
        },
    }
}

fn listener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Self) void {
    switch (event) {
        .keymap => |keymap| {
            std.debug.assert(keymap.format == wl.Keyboard.KeymapFormat.xkb_v1);
            // Read the file descriptor and create an xkb keymap from it
            const map_shm = std.posix.mmap(
                null,
                keymap.size,
                std.posix.PROT.READ,
                .{ .TYPE = .SHARED },
                keymap.fd,
                0,
            ) catch unreachable;

            const xkb_keymap = xkb.Keymap.newFromString(
                self.xkb_context.?,
                @ptrCast(map_shm),
                xkb.Keymap.Format.text_v1,
                xkb.Keymap.Flags.no_flags,
            );

            std.posix.munmap(map_shm);
            std.posix.close(keymap.fd);

            const xkb_state = xkb.State.new(xkb_keymap.?);
            if (self.xkb_state) |sstate| sstate.unref();
            if (self.xkb_keymap) |skeymap| skeymap.unref();
            self.xkb_keymap = xkb_keymap;
            self.xkb_state = xkb_state;
        },
        .enter => |_| {
            // Don't care about what is currently held
        },
        .leave => |_| {
            // Don't care
        },
        .key => |key| {
            var buf = [_]u8{42} ** 128;
            self.callback_fn(self, .{
                .serial = key.serial,
                .time = key.time,
                .keysym = self.xkb_state.?.key_get_one_sym(key.key),
                .keyUtf8 = self.xkb_state.?.key_get_utf8(key.key, &buf) catch unreachable,
                .state = key.state,
            });
        },
        .modifiers => |evt| {
            self.xkb_state.?.updateMask(
                evt.mods_depressed,
                evt.mods_locked,
                evt.mods_locked,
                0,
                0,
                evt.group,
            );
        },
        .repeat_info => |_| {
            // Not handled
        },
    }
}
