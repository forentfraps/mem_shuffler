const std = @import("std");

pub const Handle = usize; // index inside `mem_entry_array`
pub const Invalid = std.math.maxInt(Handle); // 0xFFFF_FFFF sentinel

pub const MemoryEntry = struct {
    ptr: *anyopaque,
    size: usize,
    handle: Handle,
    locked: bool,
    to_clear: bool,
};

const MemArena = struct {
    arena: *std.heap.ArenaAllocator,
    entries_indexes: std.ArrayList(usize),
    stale: bool = false,
    empty: bool = true,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Shuffler = struct {
    parent_allocator: std.mem.Allocator,
    mem_entry_array: std.ArrayList(MemoryEntry),
    arenas: std.ArrayList(MemArena),
    active_arena: usize = 0,
    handle_to_index: std.AutoHashMap(Handle, usize),
    rng: std.Random,

    const Self = @This();

    // ──────────────────────────── construction ──────────────────────────────
    pub fn init(allocator: std.mem.Allocator) !Self {
        var seed: u64 = undefined;
        std.Random.bytes(std.crypto.random, (@as([*]u8, @ptrCast(&seed))[0..8]));
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .parent_allocator = allocator,
            .mem_entry_array = std.ArrayList(MemoryEntry).init(allocator),
            .arenas = std.ArrayList(MemArena).init(allocator),
            .handle_to_index = std.AutoHashMap(Handle, usize).init(allocator),
            .rng = prng.random(),
        };
    }
    pub fn deinit(self: *Self) void {
        for (self.arenas.items) |*arena_entry| {
            arena_entry.arena.deinit();
            self.parent_allocator.destroy(arena_entry.arena);
            arena_entry.entries_indexes.deinit();
        }

        self.arenas.deinit();

        self.mem_entry_array.deinit();
        self.handle_to_index.deinit();
    }

    pub fn newHandle(self: *Self) Handle {
        var h: Handle = Invalid;
        while (h == Invalid or self.validHandle(h)) {
            h = self.rng.int(usize);
        }
        return h;
    }
    pub fn validHandle(self: *Self, h: Handle) bool {
        return self.handle_to_index.contains(h);
    }

    // ────────────────────────────── allocation ──────────────────────────────
    /// allocate `n` elements of `T`
    pub fn alloc(self: *Self, T: type, n: usize) !Handle {
        if (n == 0) @panic("alloc(0‑byte)");

        const arena_idx = try self.getArenaIndex();
        const ptr = try self.arenas.items[arena_idx].allocator().alloc(T, n);

        // reserve one slot and remember its index
        const entry_idx = self.mem_entry_array.items.len;
        try self.mem_entry_array.append(undefined);
        const entry = &self.mem_entry_array.items[entry_idx];

        const h = self.newHandle();

        entry.* = .{
            .ptr = ptr.ptr,
            .size = n,
            .handle = h,
            .locked = false,
            .to_clear = false,
        };

        try self.handle_to_index.put(h, entry_idx);

        var arena = &self.arenas.items[arena_idx]; // reacquire after allocations
        arena.empty = false;
        try arena.entries_indexes.append(entry_idx);

        return h;
    }

    /// create one `T`
    pub fn create(self: *Self, T: type) !Handle {
        if (@sizeOf(T) == 0) @panic("alloc(0‑byte)");

        const arena_idx = try self.getArenaIndex();
        const ptr = try self.arenas.items[arena_idx].allocator().create(T);

        // reserve one slot and remember its index
        const entry_idx = self.mem_entry_array.items.len;
        try self.mem_entry_array.append(undefined);
        const entry = &self.mem_entry_array.items[entry_idx];

        const h = self.newHandle();

        entry.* = .{
            .ptr = ptr,
            .size = @sizeOf(T),
            .handle = h,
            .locked = false,
            .to_clear = false,
        };

        try self.handle_to_index.put(h, entry_idx);

        var arena = &self.arenas.items[arena_idx]; // reacquire after allocations
        arena.empty = false;
        try arena.entries_indexes.append(entry_idx);

        return h;
    }
    // ───────────────────────────────  free  ─────────────────────────────────
    pub fn free(self: *Self, h: Handle) void {
        if (!self.validHandle(h)) return;
        const entry_index = self.handle_to_index.get(h).?;
        self.mem_entry_array.items[entry_index].to_clear = true;
    }

    // ─────────────────────── rent / return a typed pointer ──────────────────
    pub fn rentPointer(self: *Self, h: Handle, P: type) P {
        if (@typeInfo(P) != .pointer)
            @compileError("rentPointer needs a pointer type");
        self.shuffle() catch |e| @panic(@errorName(e));

        const entry_index = self.handle_to_index.get(h).?;
        const entry = &self.mem_entry_array.items[entry_index];
        entry.locked = true;
        return @as(P, @ptrCast(@alignCast(entry.ptr)));
    }

    pub fn returnPointer(self: *Self, h: Handle) void {
        if (!self.validHandle(h)) return;
        const entry_index = self.handle_to_index.get(h).?;
        const entry = &self.mem_entry_array.items[entry_index];
        entry.locked = false;
        self.shuffle() catch |e| @panic(@errorName(e));
    }

    // ───────────────────────── internal helpers ─────────────────────────────

    fn getArenaIndex(self: *Self) !usize {
        if (self.arenas.items.len == 0)
            try self.makeArena();
        return self.active_arena;
    }

    fn makeArena(self: *Self) !void {
        const arena_slot = try self.arenas.addOne(); // ← uninitialised memory

        const arena_ptr = try self.parent_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.parent_allocator);

        arena_slot.* = .{
            .arena = arena_ptr,
            .entries_indexes = std.ArrayList(usize).init(self.parent_allocator),
            .stale = false,
            .empty = true,
        };

        self.active_arena = self.arenas.items.len - 1;
        // return arena_slot;
    }
    pub fn getSize(self: *Self, h: Handle) usize {
        if (!self.validHandle(h)) @panic("Invalid handle");
        const entry_index = self.handle_to_index.get(h).?;
        const entry = &self.mem_entry_array.items[entry_index];
        return entry.size;
    }
    pub fn shuffle(self: *Self) !void {
        if (self.mem_entry_array.items.len == 0) return;
        var unlocked_entry_list = std.ArrayList(usize).init(self.parent_allocator);
        defer unlocked_entry_list.deinit();

        var to_clear_list = std.ArrayList(usize).init(self.parent_allocator);
        defer to_clear_list.deinit();

        var arenas_to_reset = std.ArrayList(usize).init(self.parent_allocator);
        defer arenas_to_reset.deinit();

        var empty_arena_index: ?usize = null;
        for (self.arenas.items, 0..) |*arena_entry, arena_index| {
            var freed_entries: usize = 0;
            var to_remove = std.ArrayList(usize).init(self.parent_allocator);
            defer to_remove.deinit();
            for (arena_entry.entries_indexes.items, 0..) |memory_entry_index, i| {
                const memory_entry = self.mem_entry_array.items[memory_entry_index];
                if (!memory_entry.locked) {
                    try to_remove.append(i);
                    if (memory_entry.to_clear) {
                        try to_clear_list.append(memory_entry_index);
                        freed_entries += 1;
                    } else {
                        try unlocked_entry_list.append(memory_entry_index);
                    }
                }
            }
            if (arena_entry.entries_indexes.items.len - freed_entries != to_remove.items.len) {
                arena_entry.stale = true;
                arena_entry.empty = false;
            } else {
                arena_entry.stale = false;
                arena_entry.empty = true;
                try arenas_to_reset.append(arena_index);
                if (arena_index != 0) {
                    empty_arena_index = arena_index;
                }
            }
            std.mem.sort(usize, to_remove.items, {}, comptime std.sort.desc(usize));
            for (to_remove.items) |index| {
                _ = arena_entry.entries_indexes.swapRemove(index);
            }
        }

        if (empty_arena_index) |arena_index| {
            self.active_arena = arena_index;
        } else {
            _ = try self.makeArena();
        }
        const arena_idx = try self.getArenaIndex();
        self.rng.shuffle(usize, unlocked_entry_list.items);
        (&self.arenas.items[arena_idx]).empty = false;
        try (&self.arenas.items[arena_idx]).entries_indexes.appendSlice(unlocked_entry_list.items);
        const allocator = (&self.arenas.items[arena_idx]).allocator();
        for (unlocked_entry_list.items) |entry_index| {
            const entry: *MemoryEntry = &self.mem_entry_array.items[entry_index];
            const new_ptr = try allocator.alloc(u8, entry.size);
            // std.debug.print("MEMCPY {*} <- {*}\n", .{ new_ptr, entry.ptr });
            @memcpy(new_ptr, @as([*]u8, @ptrCast(entry.ptr))[0..entry.size]);
            entry.ptr = new_ptr.ptr;
            self.handle_to_index.getEntry(entry.handle).?.value_ptr.* = entry_index;
        }
        std.mem.sort(usize, to_clear_list.items, {}, comptime std.sort.desc(usize));
        for (to_clear_list.items) |victim| {
            const last = self.mem_entry_array.items.len - 1;

            // Remove from handle map
            _ = self.handle_to_index.remove(self.mem_entry_array.items[victim].handle);

            // If we're swapping something into the removed slot:
            if (victim != last) {
                // Update handle_to_index map to reflect the new position
                const moved_handle = self.mem_entry_array.items[last].handle;
                self.handle_to_index.put(moved_handle, victim) catch unreachable;

                // Update every external reference (each arena) from "last" to "victim"
                for (self.arenas.items) |*arena| {
                    for (arena.entries_indexes.items) |*idx| {
                        if (idx.* == last) idx.* = victim;
                    }
                }
            }

            // Actually remove from mem_entry_array
            _ = self.mem_entry_array.swapRemove(victim);
        }

        for (arenas_to_reset.items) |idx| {
            if (idx == arena_idx) continue;
            var reset_arena = &self.arenas.items[idx];
            _ = reset_arena.arena.reset(.retain_capacity);
        }
    }
};
