# mem_shuffer 

*A tiny Zig library that "shuffles" heap allocations across arenas, with transparent (per‑entry) encryption and safe, typed access.*

> **TL;DR**
>
> * Allocate with `alloc(T, n)` or `create(T)` and get back an opaque `Handle`.
> * Temporarily borrow a typed pointer via `rentPointer(handle, *T)` and give it back with `returnPointer(handle)`.
> * The shuffler can periodically **move** ("shuffle") unlocked entries across arenas to fight fragmentation and frustrate memory forensics.
> * Data is **encrypted at rest**; it’s decrypted only while borrowed.

---

## Features

* **Opaque handles, not raw pointers.** Memory is referenced by `Handle` to make relocation safe.
* **AES‑CTR at rest.** Each entry is encrypted/decrypted using a counter stream derived from a per‑process key and an 8‑byte salt (plus the handle as part of the counter). Pointers you borrow are auto‑decrypted; data is re‑encrypted on return.
* **Shuffling/compaction.** Unlocked entries can be moved to a fresh arena during `shuffle()` (or automatically on borrow/return if enabled), reducing fragmentation and randomizing locations.
* **Arena backed.** Uses `std.heap.ArenaAllocator` instances that can be reset when empty.
* **Alignment preserved.** Runtime alignment is respected across moves.
* **Thread‑safe.** All public operations are protected by a `std.Thread.Mutex`.
* **Key rotation.** Swap the encryption key/salt at runtime via `rotateKey(...)` without losing data.

---

## Quick start

```zig
const std = @import("std");
const root = @import("mem_shuffle_lib");

pub fn main() !void {
    var gpa = std.heap.page_allocator; // or your allocator

    var sh = try root.Shuffler.init(gpa);
    defer sh.deinit();

    // Optional: shuffle on every borrow/return
    sh.setShuffleOnBorrowReturn(true);

    // Allocate a u32 and write to it
    const h = try sh.alloc(u32, 1);
    {
        const p = sh.rentPointer(h, *u32);
        p.* = 0xDEADBEEF;
        sh.returnPointer(h); // re‑encrypts and (optionally) shuffles
    }

    // Later: read it back
    {
        const p = sh.rentPointer(h, *u32);
        try std.testing.expectEqual(@as(u32, 0xDEADBEEF), p.*);
        sh.returnPointer(h);
    }

    // When done
    sh.free(h);     // marks for clearing
    try sh.shuffle(); // actually drops cleared entries, compacts arenas
}
```

---

## API overview

> The snippets below focus on the main surface area. See inline docs for details.

### Construction & lifetime

```zig
pub const Shuffler = struct {
    pub fn init(allocator: std.mem.Allocator) !Shuffler;
    pub fn deinit(self: *Shuffler) void;
};
```

### Allocation

```zig
pub fn alloc(self: *Shuffler, comptime T: type, n: usize) !Handle; // n > 0
pub fn create(self: *Shuffler, comptime T: type) !Handle;           // @sizeOf(T) > 0
```

### Borrow / return

```zig
pub fn rentPointer(self: *Shuffler, h: Handle, comptime P: type) P; // P must be a pointer type
pub fn returnPointer(self: *Shuffler, h: Handle) void;               // re‑encrypts and unlocks
pub fn getSize(self: *Shuffler, h: Handle) usize;                    // size in bytes
```

* While borrowed, the entry is **decrypted** and marked **locked** (it will not be moved).
* On `returnPointer`, data is **re‑encrypted** and may be shuffled depending on settings.

### Shuffling, clearing, and arenas

```zig
pub fn shuffle(self: *Shuffler) !void;          // moves unlocked entries; clears freed
pub fn free(self: *Shuffler, h: Handle) void;   // mark for clear; actual drop happens in shuffle
pub fn setShuffleOnBorrowReturn(self: *Shuffler, enable: bool) void;
```

* `shuffle()` compacts unlocked entries into an (empty) destination arena, then resets empty arenas to reclaim memory.
* `free()` does **not** immediately release memory; instead it marks the entry and it’s removed during the next shuffle.

### Security & key management

```zig
pub fn rotateKey(self: *Shuffler, new_key: ?*const [32]u8, new_salt: ?*const [8]u8) !void;
```

* If a key/salt is provided, it’s used; otherwise random values are generated.
* The shuffler decrypts any encrypted entries, swaps keys, then re‑encrypts.

### Introspection

```zig
pub fn validHandle(self: *Shuffler, h: Handle) bool;
```

---

## Invariants & guarantees

* **Handle integrity.** Internal maps ensure each `Handle` corresponds to exactly one live `MemoryEntry`.
* **Alignment.** After a shuffle, aligned allocations remain aligned (`@alignOf(T)` is preserved).
* **Pointer stability while locked.** A borrowed entry will not move across `shuffle()` calls until it is returned.
* **Thread safety.** All public methods acquire a mutex; concurrent workers can rent/return/shuffle safely.

---

## Tests (what we verify)

The repository includes a suite of `std.testing` unit tests:

* **Fuzzer:** random mix of alloc/create/free/borrow/mutate/shuffle while checking invariants.
* **Integrity:** a long‑lived allocation retains its value across many shuffles and churn.
* **Alignment:** pointers to `u64`/`f64` stay properly aligned after relocations.
* **Locked stability:** a borrowed pointer’s address is unchanged across repeated shuffles until returned.
* **Shuffle‑on‑return:** when enabled, returning a pointer usually changes its address (sanity check).
* **Key rotation:** data remains intact across key/salt changes (fixed and random).
* **Concurrency smoke:** multiple threads allocate/borrow/shuffle and we validate invariants/leaks.

Run them with:

```bash
zig build test
```

---

## Design notes

* **Why arenas?** They give fast bulk reset when empty and make compaction predictable.
* **Why AES‑CTR?** Xor‑ing a keystream lets us encrypt in place without keeping additional buffers. The counter block uses the shuffler’s salt and the entry’s handle.
* **Relocation:** During a shuffle, destinations are over‑allocated and then aligned at runtime; bytes are copied and internal maps updated before old arenas are reset.

---

## Caveats

* **You must call `returnPointer`.** Forgetting to return leaves the entry unlocked+decrypted and prevents relocation.
* **`free()` is deferred.** Memory isn’t reclaimed until the next `shuffle()`.
* **Not a general‑purpose allocator.** This is a utility for handle‑based, relocatable, encrypted allocations, not a drop‑in `Allocator` replacement.

---

## Roadmap

* Optional per‑entry lifetimes / auto‑shuffle cadence.
* Pluggable cipher/keystream and authenticated encryption.
* Stats/telemetry (bytes moved, arenas reset, shuffle durations).

---

## Installation

Add the package to your `build.zig` and import it:

```zig
const root = @import("mem_shuffle_lib");
```

> If you vendored the code, adjust the path accordingly. (A Zig package manager snippet can be added once published.)

---

## Contributing

PRs and issues welcome! Please include a failing test when reporting a bug.

---

## License

MIT
