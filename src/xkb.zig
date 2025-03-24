const std = @import("std");
const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const KeySym = enum(xkb.xkb_keysym_t) {
    Backspace = xkb.XKB_KEY_BackSpace,
    Return = xkb.XKB_KEY_Return,
    KP_Enter = xkb.XKB_KEY_KP_Enter,
    _,
};

pub const State = opaque {
    pub fn new(keymap: *Keymap) ?*State {
        return @ptrCast(xkb.xkb_state_new(@ptrCast(keymap)));
    }

    pub fn unref(self: *State) void {
        xkb.xkb_state_unref(@ptrCast(self));
    }

    pub fn key_get_one_sym(self: *State, keycode: u32) KeySym {
        return @enumFromInt(xkb.xkb_state_key_get_one_sym(@ptrCast(self), @intCast(keycode + 8)));
    }

    // WARNING: Returns a slice into the passed buffer
    pub fn key_get_utf8(self: *State, keycode: u32, buf: []u8) ![]const u8 {
        const count = xkb.xkb_state_key_get_utf8(@ptrCast(self), keycode + 8, @ptrCast(&buf[0]), buf.len);
        if (count < 0) {
            return error.InvalidKey;
        }
        return buf[0..@intCast(count)];
    }

    pub fn updateMask(
        self: *State,
        depressed_mods: xkb.xkb_mod_mask_t,
        latched_mods: xkb.xkb_mod_mask_t,
        locked_mods: xkb.xkb_mod_mask_t,
        depressed_layout: xkb.xkb_layout_index_t,
        latched_layout: xkb.xkb_layout_index_t,
        locked_layout: xkb.xkb_layout_index_t,
    ) void {
        _ = xkb.xkb_state_update_mask(
            @ptrCast(self),
            depressed_mods,
            latched_mods,
            locked_mods,
            depressed_layout,
            latched_layout,
            locked_layout,
        );
    }
};

pub const Context = opaque {
    pub const Flags = enum(c_uint) {
        no_flags = xkb.XKB_CONTEXT_NO_FLAGS,
    };

    pub fn new(flags: Flags) ?*Context {
        return @ptrCast(xkb.xkb_context_new(@intFromEnum(flags)));
    }

    pub fn unref(self: *Context) void {
        xkb.xkb_context_unref(@ptrCast(self));
    }
};

pub const Keymap = opaque {
    pub const Format = enum(c_uint) {
        text_v1 = xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
    };

    pub const Flags = enum(c_uint) {
        no_flags = xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    };

    pub fn newFromString(context: *Context, map_shm: [*]const u8, format: Format, flags: Flags) ?*Keymap {
        return @ptrCast(
            xkb.xkb_keymap_new_from_string(
                @ptrCast(context),
                map_shm,
                @intFromEnum(format),
                @intFromEnum(flags),
            ),
        );
    }

    pub fn unref(self: *Keymap) void {
        xkb.xkb_keymap_unref(@ptrCast(self));
    }
};
