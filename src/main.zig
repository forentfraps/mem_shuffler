//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const root = @import("mem_shuffle_lib");

const Foo = struct {
    x: u32,
    y: f64,
};

fn invariant(sh: *root.Shuffler) !void {
    const t = std.testing;
    var it = sh.mem_entries.iterator();
    while (it.next()) |kv| {
        const h = kv.key_ptr.*; // key from the map
        const entry = kv.value_ptr.*; // stored MemoryEntry

        try t.expectEqual(h, entry.handle);

        var found_in_arena = false;
        for (sh.arenas.items) |arena| {
            if (arena.entries.contains(h)) {
                try t.expect(!found_in_arena);
                found_in_arena = true;
            }
        }
        try t.expect(found_in_arena);
    }

    for (sh.arenas.items) |arena| {
        var a_it = arena.entries.keyIterator();
        while (a_it.next()) |h_ptr| {
            const h = h_ptr.*;
            try t.expect(sh.mem_entries.contains(h));
        }
    }

    if (sh.arenas.items.len != 0) {
        try t.expect(sh.active_arena < sh.arenas.items.len);
    }
}

test "fuzz shuffler random actions" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();

    {
        var sh = try root.Shuffler.init(gpa);
        defer sh.deinit();

        var live = std.ArrayList(root.Handle).init(gpa);
        defer live.deinit();

        var seed: u64 = undefined;
        std.crypto.random.bytes(@as([*]u8, @ptrCast(&seed))[0..8]);
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        const steps: usize = 1000;
        for (0..steps) |_| {
            const b: u8 = r.uintLessThan(u8, 255);
            switch (b & 0b11) {
                0 => {
                    // Allocate 1–128 bytes
                    const size: usize = ((b >> 2) & 0x7f) + 1;
                    try live.append(try sh.alloc(u8, size));
                },
                1 => {
                    // Create a Foo object
                    try live.append(try sh.create(Foo));
                },
                2 => if (live.items.len > 0) {
                    // Free a random live allocation
                    sh.free(live.swapRemove(r.uintLessThan(usize, live.items.len)));
                },
                3 => if (live.items.len > 0) {
                    // Mutate through a rented pointer
                    const idx = r.uintLessThan(usize, live.items.len);
                    const h = live.items[idx];
                    const p = sh.rentPointer(h, [*]u8);
                    if (sh.getSize(h) > 0) p[0] = 0x42;
                    sh.returnPointer(h);
                },
                else => continue,
            }
            try invariant(&sh);
        }
    }
    if (dbg.detectLeaks()) std.debug.print("Memory leaks detected\n", .{});
}

// ───────────────────────────────────────────────────────────────
// Integrity test: memory survives many shuffle cycles
// ───────────────────────────────────────────────────────────────

test "shuffler integrity" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();
    {
        var sh = try root.Shuffler.init(gpa);
        defer sh.deinit();

        // The primary allocation we will keep checking
        const primary = try sh.alloc(u32, 1);
        {
            const p = sh.rentPointer(primary, *u32);
            p.* = 0xDEADBEEF;
            sh.returnPointer(primary);
        }

        // Helper to stress the allocator
        var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
        const r = rng.random();

        var dummies = std.ArrayList(root.Handle).init(gpa);
        defer dummies.deinit();

        const outer = 50; // number of shuffle rounds
        for (0..outer) |round| {
            // Sprinkle some dummy allocations of random size
            const new_count = r.uintLessThan(usize, 8) + 2;
            for (0..new_count) |_| {
                const sz: usize = r.uintLessThan(usize, 64) + 1;
                try dummies.append(try sh.alloc(u8, sz));
            }

            // Randomly free a few of them (marking for clear)
            const to_free = r.uintLessThan(usize, dummies.items.len);
            var i: usize = 0;
            while (i < to_free and dummies.items.len > 0) : (i += 1) {
                sh.free(dummies.swapRemove(r.uintLessThan(usize, dummies.items.len)));
            }

            // Rent / verify / return our primary allocation
            {
                const ptr = sh.rentPointer(primary, *u32);
                try std.testing.expectEqual(@as(u32, 0xDEADBEEF), ptr.*);
                sh.returnPointer(primary);
            }

            // Maintain invariants every round
            try invariant(&sh);
            _ = round; // silence unused var warning in some zig versions
        }

        // Clean up all remaining dummies so DebugAllocator doesn't complain
        for (dummies.items) |h| sh.free(h);
        sh.shuffle() catch unreachable; // finish the clears

    }
    if (dbg.detectLeaks()) std.debug.print("Memory leaks detected\n", .{});
}

test "aligned rent stays aligned across shuffles" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();

    {
        var sh = try root.Shuffler.init(gpa);
        defer sh.deinit();

        const h64 = try sh.alloc(u64, 1);
        const hF = try sh.alloc(f64, 1);

        // create churn to force moves
        for (0..100) |_| {
            _ = try sh.alloc(u8, 1 + (std.hash.Wyhash.hash(0, &[_]u8{0}) % 64));
        }

        try sh.shuffle();
        const p64 = sh.rentPointer(h64, *u64);
        try std.testing.expect(@intFromPtr(p64) % @alignOf(u64) == 0);
        sh.returnPointer(h64);

        const pF = sh.rentPointer(hF, *f64);
        try std.testing.expect(@intFromPtr(pF) % @alignOf(f64) == 0);
        sh.returnPointer(hF);
    }

    if (dbg.detectLeaks()) std.debug.print("Memory leaks detected\n", .{});
}

test "locked entry pointer stable across shuffle" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();
    {
        var sh = try root.Shuffler.init(gpa);
        defer sh.deinit();

        const h = try sh.alloc(u32, 1);
        const p1 = sh.rentPointer(h, *u32);
        const a1 = @intFromPtr(p1);

        // hammer shuffle; while locked it shouldn't move
        for (0..50) |_| try sh.shuffle();
        const p1b = sh.rentPointer(h, *u32);
        const a2 = @intFromPtr(p1b);
        try std.testing.expectEqual(a1, a2);

        // now unlock; after a shuffle it *may* move
        sh.returnPointer(h);
        try sh.shuffle();
        const p2 = sh.rentPointer(h, *u32);
        const a3 = @intFromPtr(p2);
        // Can't assert that it MUST move, but it’s allowed to:
        try std.testing.expect(a3 % @alignOf(u32) == 0);
        sh.returnPointer(h);
    }

    if (dbg.detectLeaks()) std.debug.print("Memory leaks detected\n", .{});
}
