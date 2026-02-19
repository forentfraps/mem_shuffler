const std = @import("std");
const root = @import("mem_shuffle_lib");

const Foo = struct {
    x: u32,
    y: f64,
};

fn invariant(sh: *root.Shuffler) !void {
    const t = std.testing;

    sh.mu.lock(t.io) catch unreachable;
    defer sh.mu.unlock(t.io);

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
        var sh = try root.Shuffler.init(gpa, std.testing.io);
        defer sh.deinit();

        var live = try std.ArrayList(root.Handle).initCapacity(gpa, 1);
        defer live.deinit(gpa);

        var seed: u64 = undefined;
        std.Io.random(std.testing.io, @as([*]u8, @ptrCast(&seed))[0..8]);
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        const steps: usize = 1000;
        for (0..steps) |_| {
            const b: u8 = r.uintLessThan(u8, 255);
            switch (b & 0b11) {
                0 => {
                    // Allocate 1–128 bytes
                    const size: usize = ((b >> 2) & 0x7f) + 1;
                    try live.append(gpa, try sh.alloc(u8, size));
                },
                1 => {
                    // Create a Foo object
                    try live.append(gpa, try sh.create(Foo));
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
    if (dbg.detectLeaks() != 0) std.debug.print("Memory leaks detected\n", .{});
}

test "shuffler integrity" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();
    {
        var sh = try root.Shuffler.init(gpa, std.testing.io);
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

        var dummies = try std.ArrayList(root.Handle).initCapacity(gpa, 1);
        defer dummies.deinit(gpa);

        const outer = 50; // number of shuffle rounds
        for (0..outer) |round| {
            // Sprinkle some dummy allocations of random size
            const new_count = r.uintLessThan(usize, 8) + 2;
            for (0..new_count) |_| {
                const sz: usize = r.uintLessThan(usize, 64) + 1;
                try dummies.append(gpa, try sh.alloc(u8, sz));
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
            _ = round;
        }

        // Clean up
        for (dummies.items) |h| sh.free(h);
        sh.shuffle() catch unreachable; // finish the clears
    }
    if (dbg.detectLeaks() != 0) std.debug.print("Memory leaks detected\n", .{});
}

test "aligned rent stays aligned across shuffles" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();

    {
        var sh = try root.Shuffler.init(gpa, std.testing.io);
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

    if (dbg.detectLeaks() != 0) std.debug.print("Memory leaks detected\n", .{});
}

test "locked entry pointer stable across shuffle" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();
    {
        var sh = try root.Shuffler.init(gpa, std.testing.io);
        defer sh.deinit();

        const h = try sh.alloc(u32, 1);
        const p1 = sh.rentPointer(h, *u32);
        const a1 = @intFromPtr(p1);

        // hammer shuffle; while locked it shouldn't move
        for (0..50) |_| try sh.shuffle();
        const p1b = sh.rentPointer(h, *u32);
        const a2 = @intFromPtr(p1b);
        try std.testing.expectEqual(a1, a2);

        // now unlock; after a shuffle it may move
        sh.returnPointer(h);
        try sh.shuffle();
        const p2 = sh.rentPointer(h, *u32);
        const a3 = @intFromPtr(p2);
        try std.testing.expect(a3 % @alignOf(u32) == 0);
        sh.returnPointer(h);
    }

    if (dbg.detectLeaks() != 0) std.debug.print("Memory leaks detected\n", .{});
}

test "shuffle on return enabled -> pointer likely moves" {
    var sh = try root.Shuffler.init(std.testing.allocator, std.testing.io);
    defer sh.deinit();

    sh.setShuffleOnBorrowReturn(true);

    const h = try sh.alloc(u32, 1);
    const p1 = sh.rentPointer(h, *u32);
    const a1 = @intFromPtr(p1);
    sh.returnPointer(h); // triggers shuffle

    const p2 = sh.rentPointer(h, *u32);
    const a2 = @intFromPtr(p2);

    // With shuffle invoked, the entry is copied into a new arena allocation.
    // It's overwhelmingly likely to move; assert inequality to catch regressions.
    try std.testing.expect(a1 != a2);
    sh.returnPointer(h);
}

test "rotateKey preserves data and re-encrypts entries" {
    var sh = try root.Shuffler.init(std.testing.allocator, std.testing.io);
    defer sh.deinit();

    // Write a value
    const h = try sh.alloc(u64, 1);
    {
        const p = sh.rentPointer(h, *u64);
        p.* = 0x0123_4567_89AB_CDEF;
        sh.returnPointer(h); // ensures it's encrypted
    }

    // Rotate to known key/salt
    var key1: [32]u8 = [_]u8{0x11} ** 32;
    var salt1: [8]u8 = [_]u8{0x22} ** 8;
    try sh.rotateKey(&key1, &salt1);

    // Still intact?
    {
        const p = sh.rentPointer(h, *u64);
        try std.testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), p.*);
        sh.returnPointer(h);
    }

    // Rotate again with random key/salt
    try sh.rotateKey(null, null);

    // Still intact?
    {
        const p = sh.rentPointer(h, *u64);
        try std.testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), p.*);
        sh.returnPointer(h);
    }
}

test "concurrent alloc/rent/return smoke" {
    var dbg = std.heap.DebugAllocator(.{}){};
    const gpa = dbg.allocator();
    {
        var sh = try root.Shuffler.init(gpa, std.testing.io);
        defer sh.deinit();

        sh.setShuffleOnBorrowReturn(true);

        const threads = 4;
        const iters = 200;

        var ths: [threads]std.Thread = undefined;

        // Worker allocates, pokes, returns; sometimes frees
        const Worker = struct {
            sh: *root.Shuffler,
            iters: usize,

            const Self = @This();

            fn run(self: *Self) !void {
                var handles = try std.ArrayList(root.Handle).initCapacity(std.testing.allocator, 1);
                defer handles.deinit(std.testing.allocator);

                var prng = std.Random.DefaultPrng.init(0xBEEF_F00D ^ @intFromPtr(self));
                const r = prng.random();

                var i: usize = 0;
                while (i < self.iters) : (i += 1) {
                    const op = r.uintLessThan(u8, 4);
                    switch (op) {
                        0 => try handles.append(std.testing.allocator, try self.sh.alloc(u8, r.uintLessThan(usize, 64) + 1)),
                        1 => if (handles.items.len > 0) {
                            const idx = r.uintLessThan(usize, handles.items.len);
                            const h = handles.items[idx];
                            const p = self.sh.rentPointer(h, [*]u8);
                            if (self.sh.getSize(h) > 0) p[0] = 0x7A;
                            self.sh.returnPointer(h);
                        },
                        2 => try self.sh.shuffle(),
                        3 => if (handles.items.len > 0) {
                            self.sh.free(handles.swapRemove(r.uintLessThan(usize, handles.items.len)));
                        },
                        else => {},
                    }
                }

                // clean up
                for (handles.items) |h| self.sh.free(h);
            }
        };

        // spawn
        var workers: [threads]Worker = undefined;
        for (0..threads) |idx| {
            workers[idx] = .{ .sh = &sh, .iters = iters };
            ths[idx] = try std.Thread.spawn(.{}, Worker.run, .{&workers[idx]});
        }
        for (ths) |t| t.join();

        // finish clears and check invariants
        try sh.shuffle();
        try invariant(&sh);
    }

    if (dbg.detectLeaks() != 0) std.debug.print("Memory leaks detected\n", .{});
}
