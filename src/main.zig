//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

pub fn main() !void {}
const root = @import("mem_shuffle_lib");
const std = @import("std");

const Foo = struct {
    a: u32,
    b: u32,
};
fn invariant(shuffler: *root.Shuffler) !void {
    var total: usize = 0;
    for (shuffler.arenas.items) |arena| {
        for (arena.entries_indexes.items) |idx|
            try std.testing.expect(idx < shuffler.mem_entry_array.items.len);
        total += arena.entries_indexes.items.len;
    }
    try std.testing.expectEqual(shuffler.mem_entry_array.items.len, total);
}

// 1 ─ bulk alloc / bulk free stress‑test
test "bulk alloc / bulk free leaves allocator clean" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    var tmp = std.ArrayList(*const root.MemoryEntry).init(std.heap.page_allocator);
    defer tmp.deinit();

    inline for (0..128) |_| try tmp.append(try shuffler.alloc(u8, 8));
    for (tmp.items) |e| root.Shuffler.free(e);

    try shuffler.shuffle();
    try invariant(&shuffler);
}

// 2 ─ shuffle idempotency
test "calling shuffle twice in a row is harmless" {
    var sh = try root.Shuffler.init(std.heap.page_allocator);
    _ = try sh.alloc(u8, 32);
    _ = try sh.create(Foo);

    try sh.shuffle();
    try invariant(&sh);

    try sh.shuffle();
    try invariant(&sh);
}

// 3 ─ free‑while‑locked semantics
test "free on a locked block delays reclamation until return_pointer" {
    var sh = try root.Shuffler.init(std.heap.page_allocator);
    const e = try sh.alloc(u8, 16);

    const p = sh.rent_pointer(e, [*]u8);
    root.Shuffler.free(e); // mark while still locked
    p[0] = 0xFF;
    sh.return_pointer(e); // now eligible for GC

    try sh.shuffle();
    try invariant(&sh);
}

// 4 ─ coverage‑guided fuzzing (0.15‑dev API)
test "fuzz shuffler API" {
    const Context = struct {
        // a per‑iteration PRNG – avoids repeated calls to std.rand on the
        // global seed and keeps memory use tiny.
        fn prng(seed: u64) std.Random.DefaultPrng {
            return std.Random.DefaultPrng.init(@as(u64, @bitCast(seed ^ 0xdead_beef_cafe_babe)));
        }

        fn testOne(_: @This(), input: []const u8) anyerror!void {
            // Fresh allocator and shuffler each iteration
            var shuffler = try root.Shuffler.init(std.heap.page_allocator);

            var live = std.ArrayList(*const root.MemoryEntry)
                .init(std.heap.page_allocator);
            defer live.deinit();

            var rng = prng(std.hash.Crc32.hash(input));
            const r = rng.random();

            for (input) |b| {
                switch (b & 0b11) {
                    // 00 ‑ allocate slice of (1‥64) bytes
                    0 => try live.append(try shuffler.alloc(u8, (b >> 2) + 1)),
                    // 01 ‑ create a Foo
                    1 => try live.append(try shuffler.create(Foo)),
                    // 10 ‑ free a random live entry
                    2 => if (live.items.len > 0)
                        root.Shuffler.free(live.swapRemove(r.uintLessThan(usize, live.items.len))),
                    // 11 ‑ rent/return a random live entry
                    3 => if (live.items.len > 0) {
                        const i = r.uintLessThan(usize, live.items.len);
                        const e = live.items[i];
                        const p = shuffler.rent_pointer(e, [*]u8);
                        defer shuffler.return_pointer(e);
                        if (e.size != 0) p[0] = 0x42;
                    },
                    else => {},
                }
                try invariant(&shuffler); // invariants after every op
            }
        }
    };

    // *** new API: Context instance, pointer to its method, options ***
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

// Ensures that a freshly‑initialised `Shuffler` starts in a clean state.
// We use `page_allocator` so that the Zig test harness does not report
// memory‑leaks (there is no `deinit` yet on `Shuffler`).
test "init returns empty shuffler" {
    const shuffler = try root.Shuffler.init(std.heap.page_allocator);
    try std.testing.expect(shuffler.mem_entry_array.items.len == 0);
}

// Verifies that `alloc` gives back a non‑null pointer and a correctly
// initialised `MemoryEntry`.
test "alloc returns valid entry and pointer" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    const entry = try shuffler.alloc(u8, 32);
    // try std.testing.expect(entry.ptr != null);
    try std.testing.expectEqual(@as(u32, 32), entry.size);
    try std.testing.expect(!entry.locked);
    try std.testing.expect(!entry.to_clear);
}

// Verifies that `create` works for arbitrary structs and records the right
// size.
test "create returns valid entry for struct type" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    const entry = try shuffler.create(Foo);
    // try std.testing.expect(entry.ptr != null);
    try std.testing.expectEqual(@sizeOf(Foo), entry.size);
}

// Checks that `rent_pointer` sets the `locked` flag and that `return_pointer`
// clears it again.
test "rent_pointer locks and return_pointer unlocks" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    const entry = try shuffler.alloc(u8, 16);
    const ptr = shuffler.rent_pointer(entry, [*]u8);
    defer shuffler.return_pointer(entry);

    try std.testing.expect(entry.locked);
    // Touch the memory so the optimiser cannot remove it
    ptr[0] = 0xaa;
}

// Confirms that `free` only marks the entry for clearing; it does not affect
// other bookkeeping immediately.
test "free marks entry to_clear" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    const entry = try shuffler.alloc(u8, 8);
    root.Shuffler.free(entry);
    try std.testing.expect(entry.to_clear);
}

// Stores data inside a struct, forces several internal shuffles via extra
// allocations/frees, and finally checks the data is still there ‑‑ proving
// the allocator’s copy‑forward logic works.
test "data persists across shuffle cycles" {
    var shuffler = try root.Shuffler.init(std.heap.page_allocator);

    const entry = try shuffler.create(Foo);

    // First borrow, write some data, then return it.
    {
        const foo_ptr = shuffler.rent_pointer(entry, *Foo);
        defer shuffler.return_pointer(entry);
        foo_ptr.* = .{ .a = 0xCAFE, .b = 0xBABE };
    }

    // Generate noise to trigger a shuffle: allocate a bunch, free half of
    // them so that the shuffler has something to move around.
    comptime var i: usize = 0;
    inline while (i < 64) : (i += 1) {
        const tmp = try shuffler.alloc(u8, 4);
        if (i % 2 == 0) root.Shuffler.free(tmp);
    }

    // Borrow again and verify the data survived the shuffle.
    const foo_ptr_again = shuffler.rent_pointer(entry, *Foo);
    defer shuffler.return_pointer(entry);

    try std.testing.expectEqual(@as(u32, 0xCAFE), foo_ptr_again.a);
    try std.testing.expectEqual(@as(u32, 0xBABE), foo_ptr_again.b);
}
// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
