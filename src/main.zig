const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const Huffman = @import("huff.zig").Huffman;

const Flag = enum {
    encode,
    decode,
};

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    const usage: []const u8 = "huffman [? -d] <input file> <output file>\n";
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    var in_file: ?[]const u8 = null;
    var out_file: ?[]const u8 = null;
    var argc: usize = 0;
    // var path: [4096]u8 = undefined;
    var flag: Flag = .encode;

    while (args.next()) |arg| {
        if (argc == 0) {
            argc += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            flag = if (std.mem.containsAtLeast(u8, arg, 1, "d")) .decode else .encode;
        } else {
            if (in_file == null) in_file = arg else out_file = arg;
        }
        argc += 1;
    }

    if (in_file == null) {
        std.debug.print("{any}\n", .{error.NoInputFile});
        std.debug.print("{s}", .{usage});
        return error.NoInputFile;
    }
    in_file = try std.fs.realpathAlloc(allocator, in_file.?);
    if (out_file != null) {
        out_file = try std.fs.path.resolve(allocator, &.{out_file.?});
        std.debug.print("{s}\n", .{out_file.?});
        // out_file = try std.fs.realpathAlloc(allocator, out_file.?);
    }

    switch (flag) {
        .encode => {
            if (out_file == null) out_file = try appendString(in_file.?, ".encoded", allocator);
            const input_file = try std.fs.openFileAbsolute(in_file.?, .{});
            var output_file: std.fs.File = undefined;
            if (!std.fs.path.isAbsolute(out_file.?)) {
                output_file = try std.fs.cwd().createFile(out_file.?, .{});
            } else {
                output_file = try std.fs.createFileAbsolute(out_file.?, .{});
            }
            defer output_file.close();
            var encode_huffman = Huffman(u8).init(allocator);
            errdefer {
                encode_huffman.deinit();
                allocator.free(out_file.?);
                allocator.free(in_file.?);
                input_file.close();
                output_file.close();
            }
            defer encode_huffman.deinit();
            try encode_huffman.encode(input_file, output_file.writer());
            try stdout.print("Successfully encoded file: {s} -> {s}\n", .{ in_file.?, out_file.? });
        },
        .decode => {
            if (out_file == null) out_file = try appendString(in_file.?, "decoded", allocator);
            const input_file = try std.fs.openFileAbsolute(in_file.?, .{});
            var output_file: std.fs.File = undefined;
            if (!std.fs.path.isAbsolute(out_file.?)) {
                output_file = try std.fs.cwd().createFile(out_file.?, .{});
            } else {
                output_file = try std.fs.createFileAbsolute(out_file.?, .{});
            }
            var decode_huffman = Huffman(u8).init(allocator);
            errdefer {
                decode_huffman.deinit();
                allocator.free(out_file.?);
                allocator.free(in_file.?);
                input_file.close();
                output_file.close();
            }
            try decode_huffman.decode(input_file.reader(), output_file.writer());
            defer decode_huffman.deinit();
            try stdout.print("Successfully decoded file: {s} -> {s}\n", .{ in_file.?, out_file.? });
        },
    }
    allocator.free(in_file.?);
    allocator.free(out_file.?);

    try bw.flush(); // don't forget to flush!
}

pub fn appendString(input: []const u8, to_append: []const u8, allocator: Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const length = input.len + to_append.len;
    if (length >= 4096) return "STRING TOO BIG";
    for (0..input.len) |i| buf[i] = input[i];
    for (input.len..to_append.len + input.len) |i| buf[i] = to_append[i - input.len];
    return try allocator.dupe(u8, buf[0..length]);
}

test "string append" {
    const test1 = appendString("hello", "okay");
    try std.testing.expectEqualStrings("hellookay", test1);
}
