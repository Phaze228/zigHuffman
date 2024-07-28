const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub fn readFile(input_file: []const u8, allocator: Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const file_path = try std.fs.realpath(input_file, &buf);
    var file = try std.fs.openFileAbsolute(file_path, .{});
    return try file.readToEndAlloc(allocator, 1048576);
}

var globalDepth: usize = 0;
var totalNodes: usize = 0;
pub fn printTabs(count: usize, writer: anytype) !void {
    for (0..count) |_| try writer.writeAll("\t");
}

pub fn Values(T: type) type {
    return packed struct {
        const Null = 255;
        const Self = @This();
        freq: usize,
        data: T,

        pub fn new(data: ?T, freq: ?usize) Self {
            return Self{
                .data = data orelse Null,
                .freq = freq orelse 0,
            };
        }
    };
}

pub fn Huffman(T: type) type {
    return struct {
        const Self = @This();
        const Value = Values(T);
        const HuffmanTable = std.AutoHashMap(T, []u1);
        const Queue = std.PriorityQueue(*Node, void, Node.lessThan);
        const CodeLength: usize = 24;
        const HeaderTag: u8 = 254;
        alloc: Allocator,
        table: HuffmanTable,
        root: ?*Node,

        const Node = struct {
            values: Value,
            left: ?*Node,
            right: ?*Node,

            pub fn newNode(allocator: Allocator, data: ?T, freq: ?usize, left: ?*Node, right: ?*Node) !*Node {
                var node = try allocator.create(Node);
                node.values = Value.new(data, freq);
                node.left = left;
                node.right = right;
                return node;
            }

            pub fn makeParent(allocator: Allocator, left: *Node, right: *Node) !*Node {
                return try Node.newNode(allocator, null, left.values.freq + right.values.freq, left, right);
            }

            pub fn lessThan(
                _: void,
                a: *Node,
                b: *Node,
            ) Order {
                return std.math.order(a.values.freq, b.values.freq);
            }

            pub fn isLeaf(node: *Node) bool {
                return (node.left == null and node.right == null);
            }

            pub fn destroy(node: *Node, allocator: Allocator) void {
                if (node.left) |l| destroy(l, allocator);
                if (node.right) |r| destroy(r, allocator);
                allocator.destroy(node);
            }

            pub fn format(node: *Node, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                if (node.values.data != Value.Null) {
                    try writer.print("Leaf: {c} : {d} \n", .{ node.values.data, node.values.freq });
                } else {
                    if (node.left != null) try writer.print("Left: {}", .{node.left.?});
                    if (node.right != null) try writer.print("Right: {}", .{node.right.?});
                }
            }
        };

        pub fn init(allocator: Allocator) Self {
            return Self{
                .alloc = allocator,
                .root = null,
                .table = HuffmanTable.init(allocator),
            };
        }

        fn tableValuesDeinit(self: *Self) void {
            var valueIter = self.table.valueIterator();
            while (valueIter.next()) |val| self.alloc.free(val.*);
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |r| r.destroy(self.alloc);
            self.tableValuesDeinit();
            self.table.deinit();
        }

        pub fn createRoot(self: *Self, reader: anytype) !void {
            var frequencies = std.mem.zeroes([255]usize);
            try countFrequencies(&frequencies, reader);
            var heap = Queue.init(self.alloc, {});
            defer heap.deinit();
            for (0..frequencies.len) |i| {
                const data: T = @intCast(i);
                const freq: usize = frequencies[i];
                if (freq == 0) continue;
                const node = try Node.newNode(self.alloc, data, freq, null, null);
                try heap.add(node);
            }

            while (heap.count() > 1) {
                const l = heap.remove();
                const r = heap.remove();
                const inode = try Node.makeParent(self.alloc, l, r);
                try heap.add(inode);
            }

            self.root = heap.remove();
        }

        pub fn codesFromRoot(self: *Self, root: ?*Node, codes: []u1, index: usize) !void {
            const node = root orelse return;

            if (node.left) |l| {
                codes[index] = 0;
                try self.codesFromRoot(l, codes, index + 1);
            }

            if (node.right) |r| {
                codes[index] = 1;
                try self.codesFromRoot(r, codes, index + 1);
            }

            if (node.isLeaf()) {
                const bit_code = try self.alloc.dupe(u1, codes[0..index]);
                try self.table.put(node.values.data, bit_code);
                return;
            }
        }

        fn rootFromTable(self: *Self) !void {
            if (self.root) |r| {
                r.destroy(self.alloc);
            }
            const root = try Node.newNode(self.alloc, null, null, null, null);
            errdefer self.alloc.destroy(root);
            var tableIter = self.table.iterator();
            while (tableIter.next()) |e| {
                const char = e.key_ptr.*;
                const code = e.value_ptr.*;
                var curr_node = root;
                for (code) |bit| {
                    if (bit == 0) {
                        if (curr_node.left == null) curr_node.left = try Node.newNode(self.alloc, null, null, null, null);
                        curr_node = curr_node.left.?;
                    } else {
                        if (curr_node.right == null) curr_node.right = try Node.newNode(self.alloc, null, null, null, null);
                        curr_node = curr_node.right.?;
                    }
                }
                curr_node.values.data = char;
            }
            self.root = root;
        }

        fn tableFromHeader(self: *Self, bitreader: anytype) !void {
            var bit_count: usize = 0;
            const header = try bitreader.readBits(u8, 8, &bit_count);
            if (header != HeaderTag) return error.InvalidHeader;
            self.tableValuesDeinit();
            while (true) {
                const char = try bitreader.readBits(u8, 8, &bit_count);
                if (char == Value.Null or char == 0) break;
                const length = try bitreader.readBits(u8, 8, &bit_count);
                const prefix_code = try bitreader.readBits(u24, length, &bit_count);
                // std.debug.print("\x1b[35m{c}|{d}|{any}\x1b[0m", .{ char, length, prefix_code });
                var codes: [CodeLength]u1 = undefined;
                for (0..length) |i| {
                    const shift: u5 = @intCast(i);
                    const bit: u1 = if ((prefix_code >> shift) & 1 == 1) 1 else 0;
                    codes[length - i - 1] = bit;
                }
                // std.debug.print(" | {any}\n", .{codes[0..length]});
                try self.table.put(char, try self.alloc.dupe(u1, codes[0..length]));
            }
        }

        pub fn decode(self: *Self, reader: anytype, writer: anytype) !void {
            var bitreader = std.io.bitReader(.big, reader);
            var bit_count: usize = 0;
            try self.tableFromHeader(@constCast(&bitreader));
            try self.rootFromTable();
            var node: *Node = self.root orelse return error.InvalidRootNode;
            while (true) {
                const bit = try bitreader.readBits(u1, 1, &bit_count);
                if (bit_count == 0) break;
                if (bit == 1) node = node.right orelse return error.InvalidNode else node = node.left orelse return error.InvalidNode;
                if (node.isLeaf()) {
                    try writer.writeAll(&.{node.values.data});
                    node = self.root.?;
                }
            }
        }

        pub fn encode(self: *Self, input_file: std.fs.File, writer: anytype) !void {
            const bsize: usize = 4096;
            const reader = input_file.reader();
            try self.createRoot(reader);
            var code_buf: [24]u1 = undefined;
            try self.codesFromRoot(self.root, &code_buf, 0);
            try input_file.seekTo(0);
            var readbuf: [bsize]T = undefined;
            var bitwriter = std.io.bitWriter(.big, writer);
            var max_length: u8 = 0;
            // Header
            _ = try writer.writeAll(&.{HeaderTag});
            var tableIter = self.table.iterator();
            while (tableIter.next()) |e| {
                const char = e.key_ptr.*;
                const code = e.value_ptr.*;
                const code_length: u8 = @intCast(code.len);
                max_length = @max(max_length, code_length);
                _ = try bitwriter.write(&.{ char, code_length });
                for (code) |bit| try bitwriter.writeBits(bit, 1);
                // std.debug.print("\x1b[32m{c}|{d}|{any}\n\x1b[0m", .{ char, code_length, code });
            }
            _ = try bitwriter.write(&.{Value.Null});
            // Data
            while (true) {
                const bytes = try reader.read(&readbuf);
                for (0..bytes) |i| {
                    const code = self.table.get(readbuf[i]) orelse return error.InvalidCode;
                    // if (i + 1 == bytes) std.debug.print("{c} | {any}\n", .{ readbuf[i], code });
                    for (code) |bit| try bitwriter.writeBits(bit, 1);
                }
                if (bytes == 0) break;
            }
            // try bitwriter.flushBits();
            // std.debug.print("Max Length: {d}\n", .{max_length});
        }
    };
}

pub fn countFrequencies(counts: []usize, reader: anytype) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes = try reader.readAll(&buffer);
        if (bytes == 0) break;
        for (0..bytes) |i| {
            counts[buffer[i]] += 1;
        }
    }
}

test "enc_test / dec_test" {
    const allocator = std.testing.allocator;
    const test_file = "test_file.txt";
    const encode_test = "test_file.enc";
    const decode_test = "test_file.dec";

    const text = "The brick walls are there for a reason. The brick walls are not there to keep us out. The brick walls are there to give us a chance to show how badly we want something. Because the brick walls are there to stop the people who don’t want it badly enough. They’re there to stop the other people. ― Randy Pausch, The Last Lecture";

    var huffman = Huffman(u8).init(allocator);
    defer huffman.deinit();
    errdefer huffman.deinit();

    // create file
    var normal_text = try std.fs.cwd().createFile(test_file, .{});
    try normal_text.writer().writeAll(text);
    normal_text.close();

    // Encode
    normal_text = try std.fs.cwd().openFile(test_file, .{});
    var new_encoded_file = try std.fs.cwd().createFile(encode_test, .{});
    const output_writer = new_encoded_file.writer();
    try huffman.encode(normal_text, output_writer);
    new_encoded_file.close();
    normal_text.close();

    // //Decode
    var decode_file = try std.fs.cwd().createFile(decode_test, .{});
    const decode_writer = decode_file.writer();
    var encoded_file = try std.fs.cwd().openFile(encode_test, .{});
    const encoded_reader = encoded_file.reader();
    try huffman.decode(encoded_reader, decode_writer);

    const test_stats = try normal_text.stat();
    const encoded_stats = try encoded_file.stat();
    const decode_stats = try decode_file.stat();
    try std.testing.expect(test_stats.size > encoded_stats.size);
    try std.testing.expectEqual(test_stats.size, decode_stats.size);
    try std.fs.cwd().deleteFile(test_file);
    try std.fs.cwd().deleteFile(encode_test);
    try std.fs.cwd().deleteFile(decode_test);
}
