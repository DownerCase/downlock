const std = @import("std");
const Authenticator = @import("Authenticator.zig");
const Output = @import("Output.zig");
const Globals = @import("Globals.zig");
const wayland = @import("wayland");
const wl = wayland.client.wl;

const pango = @cImport({
    @cInclude("pango/pangocairo.h");
});

const ctime = @cImport({
    @cInclude("time.h");
});

const Self = @This();

pub const AuthContext = struct {
    prompt: []const u8 = "",
    response: [*:0]const u8 = "",
    bg_color: u32 = @as(u32, @intFromEnum(Authenticator.AuthStep.Startup)),
    authenticator: Authenticator = .{
        .callback_fn = AuthContext.onAuthUpdate,
    },

    fn onAuthUpdate(
        auth_ptr: *Authenticator,
        update: Authenticator.Update,
    ) void {
        const self: *AuthContext = @fieldParentPtr("authenticator", auth_ptr);
        if (update.prompt) |p| self.prompt = p;
        if (update.response) |r| self.response = r;
        if (update.state) |s| self.bg_color = @as(u32, @intFromEnum(s));
    }

    fn getText(self: AuthContext, alloc: std.mem.Allocator) [:0]const u8 {
        // Get datetime
        const timestamp = ctime.time(null);
        const localtime = ctime.localtime(&timestamp);
        var buf = [_]u8{0} ** 256;
        const s = ctime.strftime(
            &buf[0],
            buf.len,
            "<span line_height='0.75' size='400%%'>%X</span>\n%x",
            localtime,
        );
        // Fill the data
        return std.fmt.allocPrintZ(
            alloc,
            "{s}\n<span color='#{X}' style='oblique'>{s}</span>\n<span color='blue'>{s}</span>",
            .{ buf[0..s], self.bg_color, self.prompt, self.response },
        ) catch {
            std.log.err("Failed to format display text", .{});
            return "";
        };
    }
};

alloc: std.mem.Allocator,
pango_context: ?*pango.struct__PangoContext,
pango_fontmap: ?*pango.struct__PangoFontMap,
auth: *const AuthContext,
output: Output,

pub fn init(
    auth: *const AuthContext,
    alloc: std.mem.Allocator,
    globals: Globals,
    output: *wl.Output,
    base_dir: []const u8,
) !Self {
    const fontmap = pango.pango_cairo_font_map_new();
    pango.pango_cairo_font_map_set_default(@ptrCast(fontmap));
    const context = pango.pango_font_map_create_context(fontmap);
    return .{
        .alloc = alloc,
        .auth = auth,
        .pango_context = context,
        .pango_fontmap = fontmap,
        .output = try .init(globals, output, base_dir, Self.drawCallback),
    };
}

pub fn deinit(self: *Self) void {
    pango.pango_cairo_font_map_set_default(null);
    pango.g_object_unref(self.pango_context);
    pango.g_object_unref(self.pango_fontmap);
    self.output.deinit();
}

fn drawCallback(output_ptr: *Output, framebuffer: []align(4) u8) void {
    const self: *Self = @fieldParentPtr("output", output_ptr);

    const pool_data = std.mem.bytesAsSlice(u32, framebuffer);

    const width = self.output.width;
    const height = self.output.height;
    const stride = width * 4;

    const text = self.auth.getText(self.alloc);
    self.drawText(pool_data, width, height, stride, text);
    self.alloc.free(text);
}

fn drawText(self: *Self, buffer: []u32, width: c_int, height: c_int, stride: c_int, text: [*:0]const u8) void {
    const surface = pango.cairo_image_surface_create_for_data(
        &std.mem.sliceAsBytes(buffer)[0],
        pango.CAIRO_FORMAT_ARGB32,
        width,
        height,
        stride,
    );
    defer pango.cairo_surface_destroy(surface);
    defer pango.cairo_surface_finish(surface);

    const cr = pango.cairo_create(surface);
    defer pango.cairo_destroy(cr);
    pango.cairo_set_source_rgba(
        cr,
        0.5,
        0.5,
        0.5,
        1.0,
    );

    // Update our context for use with this Cairo context
    pango.pango_cairo_update_context(cr, self.pango_context);

    // Draw Text
    // Center coords in middle of region
    pango.cairo_translate(
        cr,
        @as(f64, @floatFromInt(width)) / 2.0,
        @as(f64, @floatFromInt(height)) / 4.0,
    );
    const layout = pango.pango_layout_new(self.pango_context);
    defer pango.g_object_unref(layout);

    var attrs: ?*pango.PangoAttrList = null;
    var buf: [*c]u8 = null; // Return pointer for parsed text
    // Parse the pango marked up text
    if (pango.FALSE == pango.pango_parse_markup(
        text, // markup_text
        -1, // length (use -1 if null terminated)
        0, // accel_marker
        &attrs, // return location for a PangoAttrList
        &buf, // Markup stripped text, caller responsible for free
        null, // accel_char
        null, // recoverable error
    )) {
        std.log.err("Failed to parse marked up text:\n'{s}'", .{text});
        return;
    }
    defer std.c.free(buf);
    pango.pango_layout_set_attributes(layout, attrs);
    pango.pango_attr_list_unref(attrs);

    pango.pango_layout_set_text(layout, buf, -1);
    pango.pango_layout_set_alignment(layout, pango.PANGO_ALIGN_CENTER);

    const desc = pango.pango_font_description_from_string("Sans Bold 27");
    const font_scale = @min(@divTrunc(width, 30), @divTrunc(height, 15));
    pango.pango_font_description_set_absolute_size(desc, @floatFromInt(font_scale * pango.PANGO_SCALE));

    pango.pango_layout_set_font_description(layout, desc);
    pango.pango_font_description_free(desc);

    // Get the size of our layout (the text)
    var textWidth = @as(c_int, 0);
    var textHeight = @as(c_int, 0);
    pango.pango_layout_get_size(layout, &textWidth, &textHeight);
    // Move our text to the center of the image (ie: -0.5 width, -0.5 height)
    pango.cairo_move_to(
        cr,
        -0.5 * @as(f64, @floatFromInt(textWidth)) / @as(f64, @floatFromInt(pango.PANGO_SCALE)),
        0,
    );

    pango.pango_cairo_show_layout(cr, layout);
}
