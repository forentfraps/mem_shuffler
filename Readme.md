# Memory Shuffler Documentation

## Overview
The Memory Shuffler system manages dynamic memory allocations efficiently using arenas, handles, and memory entry tracking to minimize memory fragmentation and improve performance. It supports allocating, deallocating, and shuffling memory blocks, providing a safe handle-based interface.

## Types

### `Handle`

An opaque identifier (`usize`) used to reference allocated memory entries. Handles are unique indices within the internal management system.

- `Invalid`: A sentinel value (`0xFFFF_FFFF`) indicating an invalid or uninitialized handle.

### `MemoryEntry`

Structure tracking each memory allocation:
- `ptr`: Pointer to the allocated memory.
- `size`: Size of the allocated memory in bytes.
- `handle`: Unique handle associated with the allocation.
- `locked`: Indicates if the memory is currently locked (in use).
- `to_clear`: Indicates if the memory should be cleared on next shuffle.

### `MemArena`

A structure representing a memory arena:
- `arena`: Underlying Zig arena allocator (`std.heap.ArenaAllocator`).
- `entries_indexes`: Indices referencing allocations within this arena.
- `stale`: Indicates if the arena has stale (unused) memory.
- `empty`: Indicates if the arena is currently empty.

### `Shuffler`

Core structure managing memory allocations:
- `parent_allocator`: The allocator from which arenas and internal structures are derived.
- `mem_entry_array`: Array of all memory entries.
- `arenas`: Array of memory arenas.
- `active_arena`: Index of the currently active arena for allocations.
- `handle_to_index`: Maps handles to their memory entry indices.
- `rng`: Random number generator used for handle creation and memory shuffling.

## Public API

### Initialization

```zig
pub fn init(allocator: std.mem.Allocator) !Shuffler
```
Initializes a new `Shuffler` instance.

### Deinitialization

```zig
pub fn deinit(self: *Shuffler) void
```
Frees all allocated arenas and internal data structures.

### Allocation

#### Allocate Multiple Elements

```zig
pub fn alloc(self: *Shuffler, T: type, n: usize) !Handle
```
Allocates memory for `n` elements of type `T`, returning a handle.

#### Allocate Single Element

```zig
pub fn create(self: *Shuffler, T: type) !Handle
```
Allocates memory for a single element of type `T`, returning a handle.

### Deallocation

```zig
pub fn free(self: *Shuffler, h: Handle) void
```
Marks memory associated with the handle for future clearing.

### Pointer Management

#### Rent Pointer

```zig
pub fn rentPointer(self: *Shuffler, h: Handle, P: type) P
```
Locks and returns a typed pointer for the given handle.

#### Return Pointer

```zig
pub fn returnPointer(self: *Shuffler, h: Handle) void
```
Unlocks the pointer associated with the given handle.

### Utility Functions

#### Check Validity of Handle

```zig
pub fn validHandle(self: *Shuffler, h: Handle) bool
```
Returns `true` if the handle refers to valid allocated memory.

#### Get Memory Size

```zig
pub fn getSize(self: *Shuffler, h: Handle) usize
```
Returns the size of the memory associated with a valid handle.

### Internal Operations

#### Shuffle Memory

```zig
pub fn shuffle(self: *Shuffler) !void
```
Reorganizes unlocked memory blocks to minimize fragmentation. Automatically called upon renting or returning pointers.

## Usage Notes

- Handles must always be validated before use.
- Rented pointers must be explicitly returned to allow shuffling.
- Memory marked for freeing (`free()`) is only cleared on subsequent shuffle operations.
- Shuffle operation reclaims unused memory and reorganizes active allocations to optimize memory layout.

This system effectively combines handle-based allocation with memory arenas, significantly optimizing performance and managing fragmentation for memory-intensive Zig applications.
