const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wlWp = wayland.client.wp;
const wlExt = wayland.client.ext;
const wlZwlr = wayland.client.zwlr;

const blur = @import("blur.zig");
const shm = @import("shm.zig");
const Globals = @import("Globals.zig");

evt_queue: *wl.EventQueue,
output: *wl.Output,
surface: *wl.Surface,
lock_surface: ?*wlExt.SessionLockSurfaceV1 = null,
_fd: std.posix.fd_t,
poolSize: u31,
pool: *wl.ShmPool,
width: u31 = 800,
height: u31 = 600,
bufferData: []align(std.heap.page_size_min) u8,
pixel_format: wl.Shm.Format = .argb8888,
screencopy_buffer_size: u31 = 0,
screencopy_ready: std.Thread.ResetEvent = .{},
screencopy: *wlZwlr.ScreencopyFrameV1,
configured: bool = false,
viewport: *wlWp.Viewport,

callback_fn: *const fn (*Self, []align(4) u8) void,

const Self = @This();

pub fn init(
    globals: Globals,
    output: *wl.Output,
    base_dir: []const u8,
    callback: @FieldType(Self, "callback_fn"),
) !Self {
    const evt_queue = try globals.display.createQueue();
    const fd = try shm.create_shm_file(base_dir);
    const initial_shm_size = 80 * 60 * 4;
    try std.posix.ftruncate(fd, initial_shm_size);

    const surface = try globals.compositor.createSurface();
    surface.setQueue(evt_queue);
    const viewport = try globals.viewporter.getViewport(surface);
    viewport.setQueue(evt_queue);
    const pool = try globals.shm.createPool(fd, initial_shm_size);
    pool.setQueue(evt_queue);
    const screencopy = try globals.screencopyManager.captureOutput(0, output);
    screencopy.setQueue(evt_queue);
    return .{
        .evt_queue = evt_queue,
        .output = output,
        .surface = surface,
        ._fd = fd,
        .poolSize = initial_shm_size,
        .pool = pool,
        .bufferData = try std.posix.mmap(
            null,
            initial_shm_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ),
        .screencopy = screencopy,
        .callback_fn = callback,
        .viewport = viewport,
    };
}

pub fn deinit(self: *Self) void {
    if (self.lock_surface) |ls| ls.destroy();
    self.pool.destroy();
    self.surface.destroy();
    self.screencopy.destroy();
    self.output.destroy();
    self.viewport.destroy();
    self.evt_queue.destroy();
    std.posix.munmap(self.bufferData);
    std.posix.close(self._fd);
}

pub fn getLockSurface(self: *Self, session_lock: *wlExt.SessionLockV1) !void {
    const lock_surface = try session_lock.getLockSurface(self.surface, self.output);
    lock_surface.setQueue(self.evt_queue);
    lock_surface.setListener(*Self, Self.lockSurfaceListener, self);
    self.lock_surface = lock_surface;
}

pub fn setScreencopyListener(self: *Self) void {
    self.screencopy.setListener(*Self, Self.screencopyListener, self);
}

pub fn drawAndCommit(self: *Self) void {
    if (!self.configured or !self.screencopy_ready.isSet()) {
        return;
    }
    const offset = self.screencopy_buffer_size;
    const stride = self.width * 4;
    const alignedBuffer = std.mem.alignInSlice(self.bufferData[offset..], 4) orelse {
        std.log.err("Failed to align frame buffer", .{});
        return;
    };
    const framebuffer = alignedBuffer[0 .. stride * self.height];
    // Copy from original screencopy into new framebuffer
    @memcpy(framebuffer, self.bufferData[0..self.screencopy_buffer_size]);

    // Draw ontop of the screencopy copy
    self.callback_fn(self, framebuffer);

    // Listener will release the buffer when the compositor is finished with it
    const buffer = self.pool.createBuffer(offset, self.width, self.height, stride, self.pixel_format) catch {
        std.log.warn("Failed to create buffer for new frame", .{});
        return;
    };
    defer buffer.destroy();
    buffer.setListener(*Self, Self.bufferListener, self);

    self.surface.attach(buffer, 0, 0);
    self.surface.damageBuffer(0, 0, self.width, self.height);
    self.surface.commit();
}

fn ensurePoolSize(self: *Self, new_size: u31) !void {
    if (new_size <= self.poolSize) return;

    // Resize fd and shm pool
    try std.posix.ftruncate(self._fd, new_size);
    self.pool.resize(new_size);
    self.poolSize = new_size;
    // Remap buffer
    self.bufferData = try std.posix.mremap(self.bufferData.ptr, self.bufferData.len, new_size, .{ .MAYMOVE = true }, null);
}

fn bufferListener(buffer: *wl.Buffer, event: wl.Buffer.Event, _: *Self) void {
    switch (event) {
        .release => {
            buffer.destroy();
        },
    }
}

fn lockSurfaceListener(surface: *wlExt.SessionLockSurfaceV1, event: wlExt.SessionLockSurfaceV1.Event, self: *Self) void {
    switch (event) {
        .configure => |evt| {
            self.viewport.setDestination(@intCast(evt.width), @intCast(evt.height));

            const bufferSize = self.screencopy_buffer_size + (self.height * self.width * 4 * 2);
            self.ensurePoolSize(bufferSize) catch {
                std.log.err("Failed to reserve additional space for lock surface", .{});
                return;
            };
            surface.ackConfigure(evt.serial);

            self.configured = true;
            self.drawAndCommit();
        },
    }
}

fn screencopyListener(screencopy_frame_v1: *wlZwlr.ScreencopyFrameV1, event: wlZwlr.ScreencopyFrameV1.Event, self: *Self) void {
    switch (event) {
        .buffer => |evt| {
            std.log.debug("Screencopy buffer: format {s}, sz {d},{d}/{d}", .{ @tagName(evt.format), evt.width, evt.height, evt.stride });
            // Screen capture is done exactly once at startup, afterwords it
            // would capture our own lockscreen so it gets the first slot in
            // our buffer.
            // The screen is copied into the second slot the blur operation
            // outputs to the first slot
            self.screencopy_buffer_size = @intCast(evt.stride * evt.height);
            const offset = self.screencopy_buffer_size;

            self.width = @intCast(evt.width);
            self.height = @intCast(evt.height);
            self.pixel_format = evt.format;

            // Create a new buffer to store the framegrab
            self.ensurePoolSize(2 * self.screencopy_buffer_size) catch {
                std.log.err("Failed to reserve space for screencopy", .{});
                return;
            };
            const screencopy_buffer = self.pool.createBuffer(
                offset,
                @as(i32, @intCast(evt.width)),
                @as(i32, @intCast(evt.height)),
                @as(i32, @intCast(evt.stride)),
                evt.format,
            ) catch {
                std.log.err("Failed to create screencopy buffer", .{});
                return;
            };
            defer screencopy_buffer.destroy();

            // Request a copy into our new buffer
            screencopy_frame_v1.copy(screencopy_buffer);
            std.log.debug("Copy requested", .{});
        },
        .flags => |evt| {
            std.log.debug("Screencopy flags: y-invert {}", .{evt.flags.y_invert});
        },
        .ready => |evt| {
            std.log.debug("Screencopy ready: {d} {d} {d}", .{ evt.tv_sec_hi, evt.tv_sec_lo, evt.tv_nsec });
            // Blur the image

            // The blur will use the second slot as the source and first slot as
            // the blurred output
            const dstBacking = std.mem.bytesAsSlice(u32, std.mem.alignInSlice(self.bufferData[0..self.screencopy_buffer_size], 4) orelse @panic("unaligned framebuffer"));
            const srcBacking = std.mem.bytesAsSlice(u32, std.mem.alignInSlice(self.bufferData[self.screencopy_buffer_size..][0..self.screencopy_buffer_size], 4) orelse @panic("unaligned framebuffer"));

            var timer = std.time.Timer.start() catch unreachable;
            timer.reset();
            blur.blur(3, srcBacking, dstBacking, self.width, self.height);
            const blurTimeNs: f64 = @floatFromInt(timer.read());
            std.log.debug("Background blur time: {d:.3}ms", .{blurTimeNs / std.time.ns_per_ms});

            // Notify
            self.screencopy_ready.set();
        },
        .failed => |_| {
            std.log.err("Screencopy failed", .{});
        },
        .damage => |evt| {
            std.log.debug("Screencopy damage: {d},{d}({d},{d})", .{ evt.x, evt.y, evt.width, evt.height });
        },
        .linux_dmabuf => |evt| {
            std.log.debug("Screencopy dmabuf {d}: {d},{d}", .{ evt.format, evt.width, evt.height });
        },
        .buffer_done => |_| {
            std.log.debug("Screencopy buffer_done", .{});
        },
    }
}
