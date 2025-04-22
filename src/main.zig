//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const root = @import("mem_shuffle_lib");

const Foo = struct { a: u32, b: u32 };

fn invariant(sh: *root.Shuffler) !void {
    var total: usize = 0;
    for (sh.arenas.items) |arena| {
        for (arena.entries_indexes.items) |idx|
            try std.testing.expect(idx < sh.mem_entry_array.items.len);
        total += arena.entries_indexes.items.len;
    }
    try std.testing.expectEqual(sh.mem_entry_array.items.len, total);
}
//
// // ───────── 1. bulk alloc / free ─────────
// test "bulk alloc / bulk free leaves allocator clean" {
//     var gpa = std.heap.DebugAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     {
//         var sh = try root.Shuffler.init(allocator);
//         defer sh.deinit();
//
//         var tmp = std.ArrayList(root.Handle).init(allocator);
//         defer tmp.deinit();
//
//         inline for (0..128) |_| try tmp.append(try sh.alloc(u8, 8));
//         for (tmp.items) |h| sh.free(h);
//
//         try sh.shuffle();
//         try invariant(&sh);
//     }
//
//     if (gpa.detectLeaks()) std.debug.print("Leaks!\n", .{});
// }
//
// // ───────── 2. shuffle idempotency ───────
test "calling shuffle twice in a row is harmless" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var sh = try root.Shuffler.init(allocator);
        defer sh.deinit();

        _ = try sh.create(Foo);
        _ = try sh.alloc(u8, 32);

        try sh.shuffle();
        try invariant(&sh);

        try sh.shuffle();
        try invariant(&sh);
    }
    if (gpa.detectLeaks()) std.debug.print("Leaks!\n", .{});
}
//
// // ───────── 3. free‑while‑locked ─────────
// test "free on a locked block delays reclamation until returnPointer" {
//     var gpa = std.heap.DebugAllocator(.{}){};
//     const allocator = gpa.allocator();
//     {
//         var sh = try root.Shuffler.init(allocator);
//         defer sh.deinit();
//         const h = try sh.alloc(u8, 16);
//
//         const p = sh.rentPointer(h, [*]u8);
//         sh.free(h); // mark while locked
//         p[0] = 0xFF;
//         sh.returnPointer(h); // unlock → now collectible
//
//         try sh.shuffle();
//         try invariant(&sh);
//     }
//
//     if (gpa.detectLeaks()) std.debug.print("Leaks!\n", .{});
// }
// // ──────── shuffle empty ────────
// test "shuffling empty shuffler does nothing" {
//     var sh = try root.Shuffler.init(std.testing.allocator);
//     defer sh.deinit();
//
//     try sh.shuffle();
//     try invariant(&sh);
// }
//
// // ──────── shuffle moves entries correctly ────────
// test "shuffle moves data correctly" {
//     var sh = try root.Shuffler.init(std.testing.allocator);
//     defer sh.deinit();
//
//     _ = try sh.alloc(u8, 4);
//     _ = try sh.alloc(u8, 4);
//     _ = try sh.alloc(u8, 4);
//     const h = try sh.alloc(u8, 4);
//     _ = try sh.alloc(u8, 4);
//     _ = try sh.alloc(u8, 4);
//     {
//         const p = sh.rentPointer(h, [*]u8);
//         defer sh.returnPointer(h);
//
//         p[0] = 0x11;
//         p[1] = 0x22;
//         p[2] = 0x33;
//         p[3] = 0x44;
//     }
//
//     try sh.shuffle();
//     try invariant(&sh);
//
//     {
//         const new_p = sh.rentPointer(h, [*]u8);
//         defer sh.returnPointer(h);
//
//         try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, new_p[0..4]);
//     }
// }
//
// // ──────── multiple shuffles ────────
// test "multiple shuffles maintain correctness" {
//     var sh = try root.Shuffler.init(std.testing.allocator);
//     defer sh.deinit();
//
//     const h1 = try sh.alloc(u8, 8);
//     const h2 = try sh.alloc(u8, 16);
//
//     for (0..10) |_| {
//         try sh.shuffle();
//         try invariant(&sh);
//
//         {
//             const p1 = sh.rentPointer(h1, [*]u8);
//             const p2 = sh.rentPointer(h2, [*]u8);
//
//             defer sh.returnPointer(h1);
//             defer sh.returnPointer(h2);
//
//             p1[0] = 0xAA;
//             p2[0] = 0xBB;
//         }
//         {
//             const p1 = sh.rentPointer(h1, [*]u8);
//             const p2 = sh.rentPointer(h2, [*]u8);
//
//             defer sh.returnPointer(h1);
//             defer sh.returnPointer(h2);
//
//             try std.testing.expectEqual(@as(u8, 0xBB), p2[0]);
//             try std.testing.expectEqual(@as(u8, 0xAA), p1[0]);
//         }
//     }
// }
//
// // ──────── shuffle after free ────────
// test "shuffle after freeing entries" {
//     var sh = try root.Shuffler.init(std.testing.allocator);
//     defer sh.deinit();
//
//     const h_keep = try sh.alloc(u8, 32);
//     const h_free = try sh.alloc(u8, 32);
//
//     sh.free(h_free);
//     try sh.shuffle();
//     try invariant(&sh);
//
//     try std.testing.expect(sh.validHandle(h_keep));
//     try std.testing.expect(!sh.validHandle(h_free));
// }
// ──────── Randomized API usage test ────────
// test "randomized shuffler API usage" {
//     var sh = try root.Shuffler.init(std.testing.allocator);
//     defer sh.deinit();
//
//     var live = std.ArrayList(root.Handle).init(std.testing.allocator);
//     defer live.deinit();
//
//     var prng = std.Random.DefaultPrng.init(0x87345029);
//     const random = prng.random();
//
//     const input = try std.testing.allocator.alloc(u8, 256);
//     defer std.testing.allocator.free(input);
//     random.bytes(input);
//
//     for (input) |b| {
//         switch (b & 0b11) {
//             0 => try live.append(try sh.alloc(u8, (b >> 2) + 1)),
//
//             1 => try live.append(try sh.create(Foo)),
//             2 => if (live.items.len > 0)
//                 sh.free(live.swapRemove(random.uintLessThan(usize, live.items.len))),
//             3 => if (live.items.len > 0) {
//                 const i = random.uintLessThan(usize, live.items.len);
//                 const h = live.items[i];
//                 const p = sh.rentPointer(h, [*]u8);
//                 if (sh.getSize(h) != 0) p[0] = 0x42;
//                 sh.returnPointer(h);
//             },
//             else => {},
//         }
//         try invariant(&sh);
//     }
// }
// // ───────── 4. coverage‑guided fuzzing ───
// test "fuzz shuffler API" {
//     const Context = struct {
//         fn prng(seed: u64) std.Random.DefaultPrng {
//             return std.Random.DefaultPrng.init(seed ^ 0xDEADBEEFCAFEBABE);
//         }
//         fn testOne(_: @This(), input: []const u8) anyerror!void {
//             var gpa = std.heap.DebugAllocator(.{}){};
//             const allocator = gpa.allocator();
//             {
//                 var sh = try root.Shuffler.init(allocator);
//                 defer sh.deinit();
//                 var live = std.ArrayList(root.Handle).init(allocator);
//                 defer live.deinit();
//
//                 var rng = prng(std.hash.Crc32.hash(input));
//                 const r = rng.random();
//
//                 for (input) |c| {
//                     std.debug.print("{d},", .{c});
//                 }
//                 std.debug.print("\n", .{});
//                 std.debug.print("len: {d}\n", .{input.len});
//                 for (input) |b| {
//                     switch (b & 0b11) {
//                         0 => try live.append(try sh.alloc(u8, (b & 0xff) + 1)),
//                         1 => try live.append(try sh.create(Foo)),
//                         2 => if (live.items.len > 0)
//                             sh.free(live.swapRemove(r.uintLessThan(usize, live.items.len))),
//                         3 => if (live.items.len > 0) {
//                             const i = r.uintLessThan(usize, live.items.len);
//                             const h = live.items[i];
//                             const p = sh.rentPointer(h, [*]u8);
//                             if (sh.getSize(h) != 0) p[0] = 0x42;
//                             sh.returnPointer(h);
//                         },
//                         else => {},
//                     }
//                     try invariant(&sh);
//                 }
//             }
//
//             if (gpa.detectLeaks()) std.debug.print("Leaks!\n", .{});
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
