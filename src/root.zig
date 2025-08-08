const std = @import("std");

const Aes256 = std.crypto.core.aes.Aes256;
const AesEnc = std.crypto.core.aes.AesEncryptCtx(Aes256);
const AesDec = std.crypto.core.aes.AesDecryptCtx(Aes256);

pub const Handle = usize;
pub const Invalid = std.math.maxInt(Handle);

pub const MemoryEntry = struct {
    ptr: *anyopaque,
    size: usize,
    alignment: u29 = 1,
    handle: Handle,
    locked: bool = false,
    to_clear: bool = false,
    encrypted: bool = false,
};

const MemArena = struct {
    arena: *std.heap.ArenaAllocator,
    /// Maps a MemoryEntry's handle -> void just to track membership
    entries: std.AutoHashMap(Handle, void),
    stale: bool = false,
    empty: bool = true,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Shuffler = struct {
    parent_allocator: std.mem.Allocator,
    /// Global table holding every live MemoryEntry keyed by its Handle
    mem_entries: std.AutoHashMap(Handle, MemoryEntry),
    /// All arenas the shuffler can use
    arenas: std.ArrayList(MemArena),
    /// Index into 'arenas'
    active_arena: usize = 0,
    /// Monotonically–increasing counter for new handles
    next_handle: Handle = 0,
    /// Aes context and related stuff to encrypt and decrypt
    aesenc: AesEnc = undefined,
    aesdec: AesDec = undefined,
    ctr_salt: [8]u8 = undefined,

    // ───── NEW: thread-safety & toggles ─────
    mu: std.Thread.Mutex = .{}, // protects all state
    shuffle_on_borrow_return: bool = false,

    const Self = @This();

    // ──────────────────────────── construction ──────────────────────────────
    pub fn init(allocator: std.mem.Allocator) !Self {
        var key: [32]u8 = undefined;
        std.crypto.random.bytes(@as([*]u8, @ptrCast(&key))[0..32]);
        var salt: [8]u8 = undefined;
        std.crypto.random.bytes(&salt);

        return .{
            .parent_allocator = allocator,
            .mem_entries = std.AutoHashMap(Handle, MemoryEntry).init(allocator),
            .arenas = std.ArrayList(MemArena).init(allocator),
            .active_arena = 0,
            .next_handle = 0,
            .aesenc = Aes256.initEnc(key),
            .aesdec = Aes256.initDec(key),
            .ctr_salt = salt,
            .mu = .{},
            .shuffle_on_borrow_return = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.arenas.items) |*arena| {
            arena.entries.deinit();
            arena.arena.deinit();
            self.parent_allocator.destroy(arena.arena);
        }
        self.arenas.deinit();
        self.mem_entries.deinit();
    }

    // ─────────────── enable/disable shuffle at borrow/return ─────
    pub fn setShuffleOnBorrowReturn(self: *Self, enable: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.shuffle_on_borrow_return = enable;
    }

    // ─────────────────────────────── handles ────────────────────────────────
    fn newHandle(self: *Self) Handle {
        // caller holds lock
        if (self.next_handle == Invalid) self.next_handle += 1;
        const h: Handle = self.next_handle;
        self.next_handle += 1;
        return h;
    }

    pub fn validHandle(self: *Self, h: Handle) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.mem_entries.contains(h);
    }

    // ───────────────────────────── arenas ───────────────────────────────────
    fn getArenaIndex(self: *Self) !usize {
        // caller holds lock
        if (self.arenas.items.len == 0)
            try self.makeArena();
        return self.active_arena;
    }

    fn makeArena(self: *Self) !void {
        // caller holds lock
        const slot = try self.arenas.addOne();
        const arena_ptr = try self.parent_allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.parent_allocator);

        slot.* = .{
            .arena = arena_ptr,
            .entries = std.AutoHashMap(Handle, void).init(self.parent_allocator),
            .stale = false,
            .empty = true,
        };

        self.active_arena = self.arenas.items.len - 1;
    }

    // ────────────────────────────── allocation ──────────────────────────────
    pub fn alloc(self: *Self, comptime T: type, n: usize) !Handle {
        if (n == 0) @panic("alloc(0-byte)");

        self.mu.lock();
        defer self.mu.unlock();

        const arena_idx = try self.getArenaIndex();
        const ptr = try self.arenas.items[arena_idx].allocator().alloc(T, n);

        const h = self.newHandle();

        try self.mem_entries.put(h, .{
            .ptr = ptr.ptr,
            .size = n * @sizeOf(T),
            .alignment = @alignOf(T),
            .handle = h,
            .locked = false,
            .to_clear = false,
            .encrypted = false,
        });

        try self.arenas.items[arena_idx].entries.put(h, {});
        self.arenas.items[arena_idx].empty = false;
        return h;
    }

    pub fn create(self: *Self, comptime T: type) !Handle {
        if (@sizeOf(T) == 0) @panic("alloc(0-byte)");

        self.mu.lock();
        defer self.mu.unlock();

        const arena_idx = try self.getArenaIndex();
        const ptr = try self.arenas.items[arena_idx].allocator().create(T);

        const h = self.newHandle();

        try self.mem_entries.put(h, .{
            .ptr = ptr,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .handle = h,
            .locked = false,
            .to_clear = false,
            .encrypted = false,
        });

        try self.arenas.items[arena_idx].entries.put(h, {});
        self.arenas.items[arena_idx].empty = false;
        return h;
    }

    // ─────────────────────────────── free ───────────────────────────────────
    pub fn free(self: *Self, h: Handle) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.mem_entries.contains(h)) return;
        self.mem_entries.getPtr(h).?.to_clear = true;
    }

    // ─────────────────────── rent / return a typed pointer ──────────────────
    pub fn rentPointer(self: *Self, h: Handle, comptime P: type) P {
        if (@typeInfo(P) != .pointer)
            @compileError("rentPointer needs a pointer type");

        self.mu.lock();
        defer self.mu.unlock();

        if (self.shuffle_on_borrow_return) {
            self.shuffleUnsafe() catch unreachable;
        }

        const entry = self.mem_entries.getPtr(h) orelse @panic("Invalid handle");
        entry.locked = true;
        self.decrypt_mementry(entry);
        entry.encrypted = false;
        return @as(P, @ptrCast(@alignCast(entry.ptr)));
    }

    pub fn returnPointer(self: *Self, h: Handle) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (!self.mem_entries.contains(h)) return;
        const entry = self.mem_entries.getPtr(h).?;
        self.encrypt_mementry(entry);
        entry.encrypted = true;
        entry.locked = false;

        if (self.shuffle_on_borrow_return) {
            self.shuffleUnsafe() catch unreachable;
        }
    }

    pub fn getSize(self: *Self, h: Handle) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const entry = self.mem_entries.get(h) orelse @panic("Invalid handle");
        return entry.size;
    }

    // ────────────────────────────  shuffle  ────────────────────────────────
    pub fn shuffle(self: *Self) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.shuffleUnsafe();
    }

    fn shuffleUnsafe(self: *Self) !void {
        // caller holds lock
        if (self.mem_entries.count() == 0) return;

        var unlocked = std.ArrayList(Handle).init(self.parent_allocator);
        defer unlocked.deinit();

        var to_clear = std.ArrayList(Handle).init(self.parent_allocator);
        defer to_clear.deinit();

        var arenas_to_reset = std.ArrayList(usize).init(self.parent_allocator);
        defer arenas_to_reset.deinit();

        // Collect unlocked or to-clear entries from each arena
        for (self.arenas.items, 0..) |*arena, idx| {
            var iter = arena.entries.keyIterator();
            while (iter.next()) |handle_ptr| {
                const h = handle_ptr.*;
                const entry = self.mem_entries.getPtr(h).?;
                if (!entry.locked) {
                    // remove from arena tracking – we will move or delete later
                    _ = arena.entries.remove(h);
                    if (entry.to_clear) {
                        try to_clear.append(h);
                    } else {
                        try unlocked.append(h);
                    }
                }
            }

            if (arena.entries.count() == 0) {
                arena.empty = true;
                try arenas_to_reset.append(idx);
            } else {
                arena.empty = false;
            }
        }

        // Pick a destination arena (reuse an empty one or create a new one)
        const dest_idx = blk: {
            for (self.arenas.items, 0..) |arena, idx| {
                if (arena.empty) break :blk idx;
            }
            try self.makeArena();
            break :blk self.active_arena;
        };

        var dest_arena = &self.arenas.items[dest_idx];
        dest_arena.empty = false;

        // Move the survivors
        const allocator = dest_arena.allocator();
        for (unlocked.items) |h| {
            const entry_ptr = self.mem_entries.getPtr(h).?;
            const old_bytes = @as([*]u8, @ptrCast(entry_ptr.ptr))[0..entry_ptr.size];

            // Over-allocate and align the destination pointer at runtime
            const extra = entry_ptr.alignment - 1;
            const new_bytes = try allocator.alloc(u8, entry_ptr.size + extra);

            const base_addr = @intFromPtr(new_bytes.ptr);
            const aligned_addr = std.mem.alignForward(usize, base_addr, entry_ptr.alignment);
            const dst_ptr = @as(*u8, @ptrFromInt(aligned_addr));
            const dst_bytes = @as([*]u8, @ptrCast(dst_ptr))[0..entry_ptr.size];

            @memcpy(dst_bytes, old_bytes);

            entry_ptr.ptr = @ptrCast(dst_ptr);
            try dest_arena.entries.put(h, {});
        }

        // Finally clear deleted handles
        for (to_clear.items) |h| {
            _ = self.mem_entries.remove(h);
        }

        // Reset arenas that became empty
        for (arenas_to_reset.items) |idx| {
            if (idx == dest_idx) continue; // keep destination intact
            _ = self.arenas.items[idx].arena.reset(.retain_capacity);
        }

        self.active_arena = dest_idx;
    }

    // ─────────────────────────── key/stream helpers ─────────────────────────
    fn xor_keystream(self: *Self, entry: *MemoryEntry) void {
        // caller holds lock
        var data = @as([*]u8, @ptrCast(entry.ptr))[0..entry.size];

        var block: [16]u8 = undefined;
        var ks: [16]u8 = undefined;

        const salt = self.ctr_salt;
        const h64: u64 = @intCast(entry.handle); // stable per entry
        var off: usize = 0;
        var ctr: u64 = 0;

        while (off < data.len) : (ctr += 1) {
            // Build counter block: [0..8)=salt, [8..16)=h64 ^ ctr
            @memcpy(block[0..8], salt[0..8]);
            std.mem.writeInt(u64, block[8..16], h64 ^ ctr, .little);

            self.aesenc.encrypt(&ks, &block);

            const take = @min(@as(usize, 16), data.len - off);
            var i: usize = 0;
            while (i < take) : (i += 1) {
                data[off + i] ^= ks[i];
            }
            off += take;
        }
    }

    fn encrypt_mementry(self: *Self, entry: *MemoryEntry) void {
        if (entry.encrypted) return;
        self.xor_keystream(entry);
        entry.encrypted = true;
    }

    fn decrypt_mementry(self: *Self, entry: *MemoryEntry) void {
        if (!entry.encrypted) return;
        self.xor_keystream(entry);
        entry.encrypted = false;
    }

    // ───── NEW: key rotation ─────
    pub fn rotateKey(self: *Self, new_key_opt: ?*const [32]u8, new_salt_opt: ?*const [8]u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        // // We can rotate while any entry is borrowed
        // // since it is unencrypted
        // var it = self.mem_entries.valueIterator();
        // while (it.next()) |entry| {
        //     if (entry.locked) return error.Busy;
        // }

        // Remember which entries were encrypted so we can restore state
        var to_reencrypt = std.ArrayList(Handle).init(self.parent_allocator);
        defer to_reencrypt.deinit();

        var it2 = self.mem_entries.iterator();
        while (it2.next()) |kv| {
            const h = kv.key_ptr.*;
            const entry_ptr = kv.value_ptr;
            if (entry_ptr.encrypted) {
                self.decrypt_mementry(entry_ptr);
                try to_reencrypt.append(h);
            }
        }

        var new_key: [32]u8 = undefined;
        var new_salt: [8]u8 = undefined;

        if (new_key_opt) |k| {
            new_key = k.*;
        } else {
            std.crypto.random.bytes(@as([*]u8, @ptrCast(&new_key))[0..32]);
        }
        if (new_salt_opt) |s| {
            new_salt = s.*;
        } else {
            std.crypto.random.bytes(&new_salt);
        }

        self.aesenc = Aes256.initEnc(new_key);
        self.aesdec = Aes256.initDec(new_key);
        self.ctr_salt = new_salt;

        for (to_reencrypt.items) |h| {
            const entry_ptr = self.mem_entries.getPtr(h).?;
            self.encrypt_mementry(entry_ptr);
        }
    }
};

