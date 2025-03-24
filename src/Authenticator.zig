const std = @import("std");
const pam = @import("pam.zig");
const wlExt = @import("wayland").client.ext;

const Keyboard = @import("Keyboard.zig");
const DrawContext = @import("DrawContext.zig");

pub const AuthStep = enum(u32) {
    _,
    pub const Startup: AuthStep = @enumFromInt(0x666666FF);
    pub const PasswordInput: AuthStep = @enumFromInt(0x666600FF);
    pub const AuthPending: AuthStep = @enumFromInt(0x22CCCCFF);
    pub const AuthFailure: AuthStep = @enumFromInt(0x666666FF);
};

const HideCharacter = "●";
const DisplayPassword = HideCharacter ** pam.MAX_RESP_SIZE;

pub const Update = struct {
    prompt: ?[]const u8 = null,
    response: ?[*:0]const u8 = null,
    state: ?AuthStep = null,
};

const Self = @This();

password: std.BoundedArray(u8, pam.MAX_RESP_SIZE) = .{},
password_event: std.Thread.ResetEvent = .{},
keyboard: Keyboard = .{
    .callback_fn = @This().keyPressCallback,
},
update_mutex: std.Thread.Mutex = .{},
update_condition: std.Thread.Condition = .{},

callback_fn: *const fn (*Self, Update) void,

fn pam_callback(
    self: *Self,
    c_num_messages: c_int,
    c_msgs: [*c][*c]const pam.Message,
    resps: [*c][*c]pam.Response,
) c_int {
    const alloc = std.heap.c_allocator;
    std.log.debug("Received {d} messages from PAM", .{c_num_messages});

    const num_messages = std.math.cast(usize, c_num_messages) orelse {
        // Shouldn't happen
        std.log.err("Negative number of messages passed to pam callback", .{});
        return @intFromEnum(pam.ReturnCode.ConvErr);
    };
    const messages = c_msgs[0..num_messages];
    const responses = alloc.alloc(pam.Response, num_messages) catch {
        std.log.err("Out of memory to allocate PAM responses", .{});
        return @intFromEnum(pam.ReturnCode.ConvErr);
    };

    for (messages, responses) |msg, *resp| {
        std.log.debug("{s}: {s}", .{ @tagName(@as(pam.MessageStyle, @enumFromInt(msg.*.msg_style))), msg.*.msg });

        if (msg.*.msg_style == @intFromEnum(pam.MessageStyle.PromptEchoOn) or msg.*.msg_style == @intFromEnum(pam.MessageStyle.PromptEchoOff)) {
            self.notifyContext(.{ .prompt = std.mem.span(msg.*.msg) });
            self.password_event.wait();
            resp.resp = alloc.dupeZ(u8, self.password.slice()) catch {
                std.log.err("Out of memory to send password to authenticate", .{});
                self.notifyContext(.{
                    .prompt = "Out of memory",
                    .state = .AuthFailure,
                });
                return @intFromEnum(pam.ReturnCode.ConvErr);
            };

            // secureZero will always write 0s and cannot be optimized away
            std.crypto.secureZero(u8, self.password.slice());
            self.password.clear();

            self.notifyContext(.{
                .prompt = "...",
                .state = .AuthPending,
            });
        } else {
            resp.resp = null;
        }
    }
    resps.* = &responses[0];
    return @intFromEnum(pam.ReturnCode.Success);
}

fn checkPassword(self: *Self, handle: *pam.Handle) pam.ReturnCode {
    // Try and authenticate
    const result = handle.authenticate(0);
    std.log.debug("pam_authenticate returned: {s}", .{@tagName(result)});
    // We always pass .Failure as the state even on success because
    // there is no "success" frame, it just unlocks
    self.notifyContext(.{ .state = .AuthFailure, .response = handle.strerror(result) });
    return result;
}

fn keyPressCallback(
    keyboard_ptr: *Keyboard,
    key: Keyboard.KeyEvent,
) void {
    const self: *Self = @fieldParentPtr("keyboard", keyboard_ptr);
    if (key.state == .released) {
        return;
    }
    if (self.password_event.isSet()) {
        // Last entry is being verified, drop inputs
        return;
    }

    switch (key.keysym) {
        .Return, .KP_Enter => {
            self.password_event.set();
        },
        .Backspace => {
            const pw_length = self.password.len;
            if (pw_length > 0) {
                // Erase character
                std.crypto.secureZero(u8, self.password.slice()[pw_length - 1 ..]);
                // Pop off
                _ = self.password.pop();
            }
        },
        else => {
            self.password.appendSlice(key.keyUtf8) catch {};
        },
    }
    // Key pressed, update screen
    self.notifyContext(.{
        .state = .PasswordInput,
        .response = "",
        .prompt = DisplayPassword[0 .. self.password.len * HideCharacter.len],
    });
}

fn notifyContext(self: *Self, update: Update) void {
    self.broadcast();
    self.callback_fn(self, update);
}

pub fn broadcast(self: *Self) void {
    self.update_mutex.lock();
    self.update_mutex.unlock();
    self.update_condition.broadcast();
}

pub fn handlePam(
    session: *wlExt.SessionLockV1,
    is_locked: *std.Thread.ResetEvent,
    state: *Self,
    user: [*:0]const u8,
) void {
    // Create an anonymous struct to create an appropriate wrapper function
    const pamConv = pam.Conversation{
        .conv = &struct {
            fn func(
                num_msg: c_int,
                msgs: [*c][*c]const pam.Message,
                resps: [*c][*c]pam.Response,
                arg_state: ?*anyopaque,
            ) callconv(.c) c_int {
                return @as(*Self, @alignCast(@ptrCast(arg_state))).pam_callback(num_msg, msgs, resps);
            }
        }.func,
        .appdata_ptr = state,
    };
    const pamHandle = pam.Handle.start("system-auth", user, &pamConv) catch {
        std.log.err("Failed to create PAM handle!", .{});
        std.process.exit(2);
    };
    var authResult = state.checkPassword(pamHandle);
    while (authResult != .Success) {
        state.password_event.reset();
        authResult = state.checkPassword(pamHandle);
    }
    session.unlockAndDestroy();
    is_locked.reset();
    state.broadcast();
    std.log.info("Unlocked", .{});
    _ = pamHandle.end(authResult);
}
