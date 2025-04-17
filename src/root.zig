//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");

pub const MemoryEntry = struct {
    ptr: *anyopaque,
    size: usize,
    locked: bool,
    to_clear: bool,
};

const MemArena = struct {
    arena: std.heap.ArenaAllocator,
    entries_indexes: std.ArrayList(usize),
    stale: bool = false,
    empty: bool = false,
};

pub const Shuffler = struct {
    parent_allocator: std.mem.Allocator,
    mem_entry_array: std.ArrayList(MemoryEntry),
    arenas: std.ArrayList(MemArena),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .parent_allocator = allocator,
            .mem_entry_array = std.ArrayList(MemoryEntry).init(allocator),
            .arenas = std.ArrayList(MemArena).init(allocator),
        };
    }

    pub fn alloc(self: *Self, T: type, size: usize) !*const MemoryEntry {
        const arena = try self.fetch_arena();
        const allocator = arena.arena.allocator();
        const ptr = try allocator.alloc(T, size);
        const entry = MemoryEntry{
            .ptr = ptr.ptr,
            .size = size,
            .locked = false,
            .to_clear = false,
        };
        try self.mem_entry_array.append(entry);
        const len = self.mem_entry_array.items.len;
        try arena.entries_indexes.append(len - 1);
        return &self.mem_entry_array.items[len - 1];
    }

    pub fn create(self: *Self, T: type) !*const MemoryEntry {
        const arena = try self.fetch_arena();
        const allocator = arena.arena.allocator();
        const ptr = try allocator.create(T);
        const entry = MemoryEntry{
            .ptr = ptr,
            .size = @sizeOf(T),
            .locked = false,
            .to_clear = false,
        };
        try self.mem_entry_array.append(entry);
        const len = self.mem_entry_array.items.len;
        try arena.entries_indexes.append(len - 1);
        return &self.mem_entry_array.items[len - 1];
    }
    fn fetch_arena(self: *Self) !*MemArena {
        if (self.arenas.items.len == 0) {
            _ = try self.make_arena();
        }
        const arena: *MemArena = &self.arenas.items[0];
        // DEBUG check
        if (arena.stale == true) {
            unreachable;
        }
        return arena;
    }

    fn make_arena(self: *Self) !*MemArena {
        const arena = std.heap.ArenaAllocator.init(self.parent_allocator);
        const arena_entry =
            MemArena{
                .arena = arena,
                .entries_indexes = std.ArrayList(usize).init(self.parent_allocator),
            };
        if (self.arenas.items.len > 0) {
            try self.arenas.append(self.arenas.items[0]);
            self.arenas.items[0] = arena_entry;
        } else {
            try self.arenas.append(arena_entry);
        }
        return &self.arenas.items[0];
    }
    pub fn free(block: *const MemoryEntry) void {
        @constCast(block).to_clear = true;
    }
    pub fn rent_pointer(self: *Self, block: *const MemoryEntry, T: type) T {
        self.shuffle() catch {
            @panic("Failed to shuffle");
        };
        @constCast(block).locked = true;
        if (@typeInfo(T) != .pointer) {
            @compileError("Should be a pointer");
        }
        return @as(T, @ptrCast(@alignCast(block.ptr)));
    }
    pub fn return_pointer(self: *Self, block: *const MemoryEntry) void {
        @constCast(block).locked = false;

        self.shuffle() catch {
            @panic("Failed to shuffle");
        };
    }
    pub fn shuffle(self: *Self) !void {
        var unlocked_entry_list = std.ArrayList(usize).init(self.parent_allocator);
        defer unlocked_entry_list.deinit();

        var to_clear_list = std.ArrayList(usize).init(self.parent_allocator);
        defer to_clear_list.deinit();

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
            std.mem.sort(usize, to_remove.items, {}, comptime std.sort.desc(usize));
            if (arena_entry.entries_indexes.items.len - freed_entries != to_remove.items.len) {
                arena_entry.stale = true;
                arena_entry.empty = false;
            } else {
                arena_entry.stale = false;
                arena_entry.empty = true;
                _ = arena_entry.arena.reset(.retain_capacity);
                empty_arena_index = arena_index;
            }
            for (to_remove.items) |index| {
                _ = arena_entry.entries_indexes.swapRemove(index);
            }
        }

        if (empty_arena_index == 0) {
            empty_arena_index = null;
        }
        std.mem.sort(usize, to_clear_list.items, {}, comptime std.sort.desc(usize));
        for (to_clear_list.items) |victim| {
            const last = self.mem_entry_array.items.len - 1;
            _ = self.mem_entry_array.swapRemove(victim);

            if (victim != last) {
                for (unlocked_entry_list.items) |*idx| {
                    if (idx.* == last) idx.* = victim;
                }
            }
        }

        const arena = block: {
            if (empty_arena_index) |arena_index| {
                const temp_arena = self.arenas.items[0];
                self.arenas.items[0] = self.arenas.items[arena_index];
                self.arenas.items[arena_index] = temp_arena;

                break :block &self.arenas.items[0];
            } else {
                const arena = try self.make_arena();
                break :block arena;
            }
        };
        std.Random.shuffle(std.crypto.random, usize, unlocked_entry_list.items);
        arena.empty = false;
        try arena.entries_indexes.appendSlice(unlocked_entry_list.items);
        const allocator = arena.arena.allocator();
        for (unlocked_entry_list.items) |entry_index| {
            const entry: *MemoryEntry = &self.mem_entry_array.items[entry_index];
            const new_ptr = try allocator.alloc(u8, entry.size);
            // std.debug.print("MEMCPY {*} <- {*}\n", .{ new_ptr, entry.ptr });
            @memcpy(new_ptr, @as([*]u8, @ptrCast(entry.ptr)));
            entry.ptr = new_ptr.ptr;
        }
    }
};
