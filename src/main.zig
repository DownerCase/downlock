const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlWp = wayland.client.wp;
const wlExt = wayland.client.ext;
const wlZwlr = wayland.client.zwlr;

const Authenticator = @import("Authenticator.zig");
const DrawContext = @import("DrawContext.zig");
const Globals = @import("Globals.zig");

const locale = @cImport({
    @cInclude("locale.h");
});

pub const std_options: std.Options = .{
    // Set the log level depending on build mode
    .log_level = if (@import("builtin").mode == .Debug) .debug else .info,
};

const OutputThread = struct {
    thread: std.Thread,
    global_id: u32,
    stop: std.Thread.ResetEvent = .{},

    pub fn undefinit(self: *OutputThread, state: *OurState, output: *wl.Output, global_id: u32) !void {
        self.stop = .{};
        self.thread = try std.Thread.spawn(
            .{},
            OutputThread.handleOutput,
            .{ &self.stop, state, output },
        );
        self.global_id = global_id;
    }

    pub fn deinit(self: *OutputThread) void {
        if (self.global_id != 0) {
            self.stop.set();
            self.thread.join();
            self.global_id = 0;
        }
    }

    fn handleOutput(
        stop: *std.Thread.ResetEvent,
        state: *OurState,
        output: *wl.Output,
    ) void {
        var draw_context = DrawContext.init(
            &state.auth_context,
            state.alloc,
            state.globals,
            output,
            std.posix.getenv("XDG_RUNTIME_DIR") orelse "/dev/shm",
        ) catch {
            std.log.err("Failed to init output", .{});
            state.session_lock_pending_screencaps.finish();
            return;
        };
        defer draw_context.deinit();
        draw_context.output.setScreencopyListener();

        // Wait for the screen copy to complete, dispatching immediately
        while (!draw_context.output.screencopy_ready.isSet()) {
            std.log.debug("Waiting for screencopy", .{});
            _ = state.globals.display.dispatchQueue(draw_context.output.evt_queue);
            std.Thread.yield() catch {}; // Let another thread go
        }

        // Let main thread know our screen copy is complete
        state.session_lock_pending_screencaps.finish();

        // Wait for the session to be locked
        state.session_locked.wait();

        if (state.session_lock) |sl| {
            draw_context.output.getLockSurface(sl) catch {
                std.log.err("Failed to get lock surface for output", .{});
            };
        } else {
            // Should never occur
            std.log.warn("No session lock acquired!", .{});
        }

        // Immediately display the first frame
        _ = state.globals.display.roundtripQueue(draw_context.output.evt_queue);

        while (!stop.isSet()) {
            _ = state.globals.display.dispatchQueuePending(draw_context.output.evt_queue);
            {
                state.auth_context.authenticator.update_mutex.lock();
                defer state.auth_context.authenticator.update_mutex.unlock();
                state.auth_context.authenticator.update_condition.timedWait(
                    &state.auth_context.authenticator.update_mutex,
                    std.time.ns_per_ms * 100,
                ) catch {
                    continue;
                };
            }
            draw_context.output.drawAndCommit();
            _ = state.globals.display.dispatchQueue(draw_context.output.evt_queue);
        }
    }
};

const OurState = struct {
    alloc: std.mem.Allocator,
    globals: Globals,
    registry: *wl.Registry,

    // SegmentedList does not copy around elements when resizing
    outputs: std.SegmentedList(OutputThread, 8),
    session_lock: ?*wlExt.SessionLockV1 = null,
    session_locked: std.Thread.ResetEvent = .{},
    session_lock_pending_screencaps: std.Thread.WaitGroup = .{},

    // Password management
    auth_context: DrawContext.AuthContext,

    const SetupGlobals = struct {
        // Globals
        compositor: ?*wl.Compositor = null,
        shm: ?*wl.Shm = null,
        seat: ?*wl.Seat = null,
        sessionLockManager: ?*wlExt.SessionLockManagerV1 = null,
        screencopyManager: ?*wlZwlr.ScreencopyManagerV1 = null,
        viewporter: ?*wayland.client.wp.Viewporter = null,
    };

    fn init(
        alloc: std.mem.Allocator,
        display: *wl.Display,
    ) !OurState {
        var setup_globals = OurState.SetupGlobals{};
        const registry = try display.getRegistry();
        registry.setListener(*SetupGlobals, registrySetupListener, &setup_globals);

        // Block until all pending requests are processed
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        registry.destroy();

        return OurState{
            .alloc = alloc,
            .registry = try display.getRegistry(),
            .globals = .{
                .compositor = setup_globals.compositor.?,
                .shm = setup_globals.shm.?,
                .seat = setup_globals.seat.?,
                .sessionLockManager = setup_globals.sessionLockManager.?,
                .screencopyManager = setup_globals.screencopyManager.?,
                .viewporter = setup_globals.viewporter.?,
                .display = display,
            },
            .outputs = .{},
            .auth_context = .{},
        };
    }

    fn deinit(state: *OurState) void {
        state.auth_context.authenticator.keyboard.deinit();

        // Signal all outputs to stop
        var it = state.outputs.iterator(0);
        while (it.next()) |output| output.stop.set();
        // Try and wake all threads
        state.auth_context.authenticator.update_condition.broadcast();
        // Join all threads
        it = state.outputs.iterator(0);
        while (it.next()) |output| output.deinit();
        state.outputs.deinit(state.alloc);

        state.globals.shm.destroy();
        state.globals.seat.destroy();
        state.globals.viewporter.destroy();
        state.globals.compositor.destroy();
        state.globals.screencopyManager.destroy();
        state.globals.sessionLockManager.destroy();
        state.registry.destroy();
    }
};

fn c_str_eq(a: [*c]const u8, b: [*c]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

// Listener functions
fn registrySetupListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *OurState.SetupGlobals) void {
    switch (event) {
        .global => |evt| {
            // std.debug.print("Global: name = {d}, interface = {s}, version = {d}\n", .{ evt.name, evt.interface, evt.version });
            if (c_str_eq(evt.interface, wl.Compositor.interface.name)) {
                globals.compositor = registry.bind(evt.name, wl.Compositor, 4) catch unreachable;
            } else if (c_str_eq(evt.interface, wl.Shm.interface.name)) {
                globals.shm = registry.bind(evt.name, wl.Shm, 1) catch unreachable;
                // TODO: Consider adding a listener to get the pixel formats
            } else if (c_str_eq(evt.interface, wl.Seat.interface.name)) {
                globals.seat = registry.bind(evt.name, wl.Seat, 7) catch unreachable;
            } else if (c_str_eq(evt.interface, wlExt.SessionLockManagerV1.interface.name)) {
                globals.sessionLockManager = registry.bind(evt.name, wlExt.SessionLockManagerV1, 1) catch unreachable;
            } else if (c_str_eq(evt.interface, wlZwlr.ScreencopyManagerV1.interface.name)) {
                globals.screencopyManager = registry.bind(evt.name, wlZwlr.ScreencopyManagerV1, 1) catch unreachable;
            } else if (c_str_eq(evt.interface, wlWp.Viewporter.interface.name)) {
                globals.viewporter = registry.bind(evt.name, wlWp.Viewporter, 1) catch unreachable;
            } else {
                // Don't care
            }
        },
        .global_remove => |evt| {
            std.log.warn("Setup Global remove {d}", .{evt.name});
        },
    }
}

fn registryOutputListener(registry: *wl.Registry, event: wl.Registry.Event, self: *OurState) void {
    switch (event) {
        .global => |evt| {
            if (c_str_eq(evt.interface, wl.Output.interface.name)) {
                const global_output = registry.bind(evt.name, wl.Output, 4) catch unreachable;
                // Wayland won't reuse an id whilst its in use
                const new_output = self.outputs.addOne(self.alloc) catch {
                    std.log.err("Failed to allocate for new output", .{});
                    return;
                };
                // Register we are waiting for a screencap
                self.session_lock_pending_screencaps.start();
                new_output.undefinit(self, global_output, evt.name) catch {
                    std.log.err("Failed to initialize new output", .{});
                    return;
                };
                std.log.info("Attached output {d}", .{evt.name});
            }
        },
        .global_remove => |evt| {
            var it = self.outputs.iterator(0);
            while (it.next()) |o| {
                if (o.global_id != evt.name) continue else {
                    std.log.debug("Disconnecting output {d}", .{evt.name});
                    o.deinit();
                    std.log.info("Disconnected output {d}", .{evt.name});
                }
            }
        },
    }
}

// Application
pub fn main() !void {
    // Be portable to all locales
    _ = locale.setlocale(locale.LC_ALL, "");
    std.log.info("Starting DownLock", .{});

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    // Flush any pending events (i.e.: `destroy` calls before shutting down)
    defer _ = display.roundtrip();

    const alloc = std.heap.c_allocator;
    var state = try OurState.init(alloc, display);
    defer state.deinit();

    state.registry.setListener(*OurState, registryOutputListener, &state);

    // Wire global context keyboard and seat together
    state.auth_context.authenticator.keyboard.attachSeat(state.globals.seat);

    // Block until all pending requests are processed
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Handle the authentication
    const user = getUser: {
        const uidpw = std.c.getpwuid(std.os.linux.getuid()) orelse {
            std.log.err("Could not get current user", .{});
            std.process.exit(1);
        };
        break :getUser uidpw.name orelse {
            std.log.err("Username not filled", .{});
            std.process.exit(1);
        };
    };

    // Screen captures must complete before locking, or it will be all black...
    while (!state.session_lock_pending_screencaps.isDone()) {
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        state.session_lock_pending_screencaps.event.timedWait(std.time.ns_per_ms * 10) catch {};
    }

    // Get a session lock
    var sessionLock = try state.globals.sessionLockManager.lock();
    sessionLock.setListener(*OurState, lockListener, &state);
    // Assign the session lock and let the Outputs know
    state.session_lock = sessionLock;
    state.session_locked.set();

    const auth_thread = try std.Thread.spawn(.{}, Authenticator.handlePam, .{
        sessionLock,
        &state.session_locked,
        &state.auth_context.authenticator,
        user,
    });
    defer auth_thread.join();

    const clock_thread = try std.Thread.spawn(.{}, clockTicker, .{
        &state.auth_context.authenticator,
        &state.session_locked,
    });
    defer clock_thread.join();

    while (state.session_locked.isSet()) {
        // Handle events
        if (display.dispatch() != .SUCCESS) return error.RoundtripFailed;
    }

    std.log.info("Closing", .{});
}

fn clockTicker(authenticator: *Authenticator, is_locked: *std.Thread.ResetEvent) void {
    // Redraw the frame at least once per second
    while (is_locked.isSet()) {
        std.Thread.sleep(std.time.ns_per_s);
        authenticator.broadcast();
    }
}

fn lockListener(session_lock_v1: *wlExt.SessionLockV1, event: wlExt.SessionLockV1.Event, state: *OurState) void {
    switch (event) {
        .locked => {
            std.log.info("Session locked", .{});
        },
        .finished => {
            std.log.info("Session forcibly unlocked", .{});
            session_lock_v1.unlockAndDestroy();
            state.session_locked.reset();
        },
    }
}
