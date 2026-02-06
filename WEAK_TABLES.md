# Weak Tables Analysis for VM Cache

## What Are Weak Tables?

Weak tables in Lua are tables where entries can be automatically collected by the garbage collector, even if they're still referenced in the table. This is controlled by the `__mode` metatable field:

- `__mode = "k"`: Weak keys - keys can be collected
- `__mode = "v"`: Weak values - values can be collected  
- `__mode = "kv"`: Both keys and values are weak

## Should We Use Weak Tables for the VM Cache?

**Short answer: NO** (but it's available as an experimental option)

## Analysis

### Current Cache Design

The VM cache in Mapblock Shepherd:
- Stores VoxelManip data for blocks during a processing round
- Includes both focal blocks (being processed) and peripheral blocks (neighbors)
- Explicitly cleared when the work queue is empty (round complete)
- Sized by the number of blocks in the queue plus their neighbors
- Typical memory: ~2.4MB for 50 blocks with 3 neighbors each

### What Weak Values Would Do

With `__mode = "v"`, the Lua garbage collector could reclaim cache entries at any time when:
- Memory pressure occurs
- No other references exist to the cached data
- A GC cycle runs

### Pros of Weak Tables

1. **Automatic memory management**: GC handles cleanup
2. **Graceful degradation**: Under memory pressure, cache shrinks automatically
3. **No hard size limits**: Don't need to pick a magic number for cache size
4. **Self-tuning**: Adapts to available memory

### Cons of Weak Tables (Why We Don't Use Them)

1. **Unpredictable behavior**: Cache entries can vanish mid-round
   - A block loaded as focal might be GC'd before being accessed as peripheral
   - Defeats the entire purpose of caching neighbors

2. **Performance inconsistency**: 
   - Same block might be loaded multiple times in one round
   - Random performance variations make debugging hard
   - Users expect consistent performance

3. **Design conflict**: 
   - We WANT deterministic cache lifetime (entire round)
   - Weak tables provide non-deterministic lifetime
   - Current design assumes cache survives the round

4. **Questionable benefit**:
   - Memory usage is already bounded by round size
   - Rounds complete in seconds, cache is short-lived
   - Manual clearing is simple and works fine

5. **When GC runs is unpredictable**:
   - Might not run when you need it (memory still grows)
   - Might run when you don't want it (mid-round)
   - Can't control GC timing precisely

### When Weak Tables ARE Useful

Weak tables work well for:
- Long-lived caches with unpredictable access patterns
- "Nice to have" caching where loss is acceptable
- When you can't predict good eviction strategies
- Memoization caches for pure functions
- Event listener registrations (to avoid memory leaks)

### When Weak Tables Are NOT Useful

Weak tables are bad for:
- Performance-critical caches (unpredictable!)
- Short-lived caches with explicit lifecycle management
- When cache hits are essential for correctness
- When deterministic behavior is required
- Our use case (VM cache for processing rounds)

## Better Alternatives for Memory Management

If memory becomes an issue, consider:

1. **Explicit LRU cache**: 
   - Keep N most recently used entries
   - Predictable and tuneable
   - Example: Keep last 100 blocks, evict oldest

2. **Process in smaller batches**:
   - Limit work queue size
   - More frequent cache clearing
   - Better for memory-constrained servers

3. **Increase server RAM**:
   - 2-3MB cache is tiny by modern standards
   - Proper solution for performance

4. **Streaming approach**:
   - Process blocks one at a time
   - Don't cache at all
   - Simpler but slower

## Experimental Option

Despite the recommendation against it, weak tables are available as an experimental option in `shepherd.lua`:

```lua
-- Set to true to enable weak tables (NOT recommended)
local USE_WEAK_CACHE = false
```

Enable this only if:
- You're experiencing severe memory pressure
- You understand the performance tradeoffs
- You're willing to debug non-deterministic cache behavior
- You want to experiment and measure the impact

## Conclusion

For the Mapblock Shepherd VM cache, weak tables are **not appropriate**. The cache has:
- A defined lifecycle (processing round)
- Explicit clearing at the right time (queue empty)
- Bounded memory usage (acceptable)
- Need for deterministic behavior (performance-critical)

The current design is correct. Weak tables would introduce unpredictability without meaningful benefit.

## References

- Lua 5.1 Reference Manual: Weak Tables
- Programming in Lua: Weak Tables and Finalizers
- Lua Users Wiki: Weak Tables Tutorial
