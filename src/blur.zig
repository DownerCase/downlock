// Acknowledgements:
// https://www.peterkovesi.com/papers/FastGaussianSmoothing.pdf
// https://github.com/bfraboni/FastGaussianBlur
// https://blog.ivank.net/fastest-gaussian-blur.html
const std = @import("std");

fn boxesForGauss(comptime n: comptime_int, sigma: comptime_float) [n]u32 {
    const sigmaSq = sigma * sigma;
    // Ideal filter width will be some non-integer value
    const widthIdeal = std.math.sqrt((12 * sigmaSq / n) + 1);
    // We need filters with odd width such that there is a central pixel
    // So we pick the nearest odd integers above and below our ideal value
    const widthLower: comptime_int = lowerWidth: {
        var wl: comptime_int = @intFromFloat(widthIdeal);
        if (wl % 2 == 0) {
            wl -= 1;
        }
        break :lowerWidth wl;
    };
    const widthUpper = widthLower + 2;

    // With the two filter sizes we calculate how many passes of each we need
    // It will be m Lower passes and n-m upper passes
    const mLowerPassesIdeal = (12 * sigmaSq - n * widthLower * widthLower - 4 * n * widthLower - 3 * n) / @as(comptime_float, @floatFromInt(-4 * widthLower - 4));
    const mLowerPasses: comptime_int = @intFromFloat(@round(mLowerPassesIdeal));

    return widths: {
        var ws: [n]u32 = @splat(widthUpper);
        for (0..mLowerPasses) |m| {
            ws[m] = widthLower;
        }
        break :widths ws;
    };
}

test "boxWidths" {
    const expected_widths = [_]u32{
        5,
        5,
        7,
    };
    inline for (expected_widths, comptime boxesForGauss(3, 3)) |expected, actual| {
        try comptime std.testing.expectEqual(expected, actual);
    }
}

fn blur_horizontal_box(src: []const u32, dst: []u32, width: u32, height: u32, comptime radius: u31) void {
    const diameter = 2 * radius + 1;
    // Fixed point scaled scaling factor. Scaled by 2^16
    const iarr: @Vector(4, u32) = comptime @splat(@intFromFloat(@exp2(16.0) / @as(f32, @floatFromInt(radius + radius + 1))));
    for (0..height) |y| {
        const srcRow: []const @Vector(4, u8) = @ptrCast(src[y * width ..][0..width]);
        var dstRow: []@Vector(4, u8) = @ptrCast(dst[y * width ..][0..width]);
        var acc: @Vector(4, u32) = @splat(0);

        // Accumulate the initial values within the radius
        for (0..radius) |i| {
            acc += srcRow[i];
        }

        // Right index = currentIdx + radius
        // Left index = currentIdx - 1 - radius

        // Left side of filter is outside, right side inside
        for (0..radius + 1) |i| {
            acc += srcRow[i + radius];
            dstRow[i] = @intCast((acc * iarr) >> @splat(16));
        }

        // Filter is fully inside
        for (0..width - diameter) |i| {
            acc = acc - srcRow[i] + srcRow[i + diameter];
            dstRow[i + radius + 1] = @intCast((acc * iarr) >> @splat(16));
        }

        // Right side of filter is outside, left side inside
        for (0..radius) |i| {
            acc -= srcRow[i + width - diameter];
            dstRow[i + width - radius] = @intCast((acc * iarr) >> @splat(16));
        }
    }
}

fn transpose(src: []u32, dst: []u32, width: u32, height: u32) void {
    // For each row
    for (0..height) |y| {
        // And each column
        for (0..width) |x| {
            dst[(x * height) + y] = src[(y * width) + x];
        }
    }
}

pub fn blur(comptime sigma: u32, src: []u32, dst: []u32, width: u32, height: u32) void {
    // Get u24 fixed point weights
    const boxWeights = comptime boxesForGauss(3, sigma);

    // Horizontal blur
    blur_horizontal_box(src, dst, width, height, boxWeights[0]);
    blur_horizontal_box(dst, src, width, height, boxWeights[1]);
    blur_horizontal_box(src, dst, width, height, boxWeights[2]);

    // Vertical blur (don't forget to swap width and height!)
    transpose(dst, src, width, height);
    blur_horizontal_box(src, dst, height, width, boxWeights[0]);
    blur_horizontal_box(dst, src, height, width, boxWeights[1]);
    blur_horizontal_box(src, dst, height, width, boxWeights[2]);

    // Restore to original layout
    transpose(dst, src, height, width);
    @memcpy(dst[0 .. width * height], src[0 .. width * height]);
}
