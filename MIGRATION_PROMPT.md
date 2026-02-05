# Comprehensive Prompt for Recreating Mapblock Shepherd Migration

This is a comprehensive prompt that consolidates all the work done on the `copilot/rebase-and-update-shepherd-for-mapblocks` branch. Use this to recreate the same changes on a new branch.

---

## Main Objective

Migrate the Mapchunk Shepherd mod from a mapchunk-based architecture to a mapblock-based architecture using Luanti's native block callback system. This involves:

1. Replacing the player tracker system with Luanti's block callbacks
2. Processing individual mapblocks (16x16x16) instead of mapchunks (80x80x80)
3. Refactoring the hash API to use Luanti's standard format publicly while keeping internal storage format
4. Updating all documentation to reflect the new architecture

---

## Specific Tasks

### Part 1: Migrate from Mapchunks to Mapblocks with Block Callbacks

**Context:** The original system tracked player positions and processed "mapchunks" (5x5x5 mapblocks). The new system should use Luanti's block callback API to process individual mapblocks.

**Required Changes:**

1. **Replace Player Tracker with Block Callbacks** (in `shepherd.lua`):
   - Remove the player tracker system that monitored player positions
   - Implement Luanti's block callback system:
     - `core.register_on_block_loaded(function(blockpos))` - queue newly loaded blocks
     - `core.register_on_block_activated(function(blockpos))` - mark blocks as active (priority processing)
     - `core.register_on_block_deactivated(function(blockpos_list))` - demote blocks from active status
     - `core.register_on_block_unloaded(function(blockpos_list))` - remove blocks from queue
   
2. **Update Block Queue Management** (in `shepherd.lua`):
   - Track blocks using Luanti hashes: `core.hash_node_position(blockpos)`
   - Maintain a queue with priority levels (active blocks vs loaded blocks)
   - Process active blocks first (they're closer to players)
   - Main loop: every 1 second, process up to 5 blocks per tick
   - Sort blocks by priority before processing
   - Verify blocks are still loaded using `core.loaded_blocks[hash]` before processing

3. **Update Voxel Manipulator Size** (in `dogs.lua` and related files):
   - Change from mapchunk size (80x80x80 nodes) to mapblock size (16x16x16 nodes)
   - Update `mapblock_side` constant to 16
   - Adjust all voxel manipulator operations accordingly

4. **Remove Ignore Node Failure Handling** (in `dogs.lua`):
   - Remove all checks for "ignore" nodes and "worker_failed" labels
   - Mapblocks are atomic units (fully loaded or not), so no partial loading issues
   - Simplify worker functions: `create_simple_replacer`, `create_param2_aware_replacer`, `create_light_aware_replacer`, `create_light_aware_top_placer`, `create_neighbor_aware_replacer`

5. **Update All API Calls** (across all `.lua` files):
   - Change `minetest.*` to `core.*` throughout the codebase for consistency
   - This aligns with Luanti's naming conventions

---

### Part 2: Refactor Hash API to Hide Internal Format

**Context:** The mod's internal base64-encoded hash format ("x_y_z") was exposed in the public API. It should only be used internally for mod storage, while the public API should use Luanti's standard `core.hash_node_position()` format.

**Required Changes:**

1. **Make Internal Hash Functions Private** (in `chunk_utils.lua`):
   - Rename `ms.hash()` to local `internal_hash()`
   - Rename `ms.unhash()` to local `internal_unhash()`
   - Add conversion functions (private):
     - `luanti_to_internal_hash(luanti_hash)` - converts Luanti hash to internal format
     - `internal_to_luanti_hash(internal_hash_val)` - converts internal to Luanti format

2. **Update Public API Functions** (in `chunk_utils.lua`):
   - `ms.mapblock_hash(pos)` - return `core.hash_node_position(coords)` instead of internal format
   - `ms.mapchunk_hash(pos)` - return `core.hash_node_position(coords)` instead of internal format
   - `ms.mapblock_hash_to_pos(hash)` - accept Luanti hash, use `core.get_position_from_hash()`
   - `ms.mapchunk_hash_to_pos(hash)` - accept Luanti hash, use `core.get_position_from_hash()`
   - `ms.mapblock_min_max(hash)` - accept Luanti hash
   - `ms.mapchunk_min_max(hash)` - accept Luanti hash
   - `ms.save_time(hash)` - accept Luanti hash, convert to internal before storage
   - `ms.reset_time(hash)` - accept Luanti hash, convert to internal before storage
   - `ms.time_since_last_change(hash)` - accept Luanti hash, convert to internal before storage
   - Add `ms.get_labels(hash)` helper function

3. **Update Label Store** (in `label_store.lua`):
   - `label_store.new(hash)` - accept Luanti hash
   - Add `internal_hash` field to store the internal format for mod storage
   - Convert Luanti hash to internal format using: `core.encode_base64(blockpos.x.."_"..blockpos.y.."_"..blockpos.z)`
   - Update `read_from_disk()` and `save_to_disk()` to use `internal_hash`
   - Update `set_hash()` to accept Luanti hash and convert

4. **Simplify Shepherd Block Tracking** (in `shepherd.lua`):
   - Remove dual hash tracking (was: `hash` and `our_hash`)
   - Use only Luanti standard hash throughout
   - All worker callbacks receive Luanti hash format

---

### Part 3: Update Documentation

**Required Changes in `README.md`:**

1. **Update Title and Introduction:**
   - Change from "Mapchunk Shepherd" to "Mapblock Shepherd"
   - Update description to focus on mapblocks instead of mapchunks

2. **Update General Idea Section:**
   - Replace player movement tracking with block callback system
   - Focus on mapblocks as the unit of processing

3. **Update Features Section:**
   - Remove player tracker mentions
   - Add block callback system features
   - Emphasize active block prioritization

4. **Update Terminology Section:**
   - Remove: Chunk size, Mapchunk, Mapchunk offset, Player tracker, Neighborhood, Failed block
   - Simplify Label definition (remove "with a corresponding binary ID")
   - Update Mapblock hash description to mention Luanti standard format
   - Replace "Work queue" with two new sections:
     - **Block Queue**: Explain the queue, block callbacks, and priority levels
     - **Block Processing**: Explain the processing loop, timing, and label-based filtering

5. **Remove Mentions of:**
   - "corresponding binary ID" (outdated terminology)
   - Player tracker and neighborhoods
   - "worker_failed" and ignore node failures
   - Custom hash encoding in public API

---

## Implementation Order

1. First, change all `minetest.*` to `core.*` across all files
2. Implement block callback system in `shepherd.lua`
3. Update voxel manipulator size to mapblock (16x16x16)
4. Refactor hash API to use Luanti standard format publicly
5. Update label_store to handle hash conversion
6. Remove ignore node failure handling
7. Update README documentation
8. Test thoroughly

---

## Key Points to Remember

- Mapblocks are 16x16x16 nodes (atomic units)
- Active blocks (near players) should be processed before loaded blocks
- Processing limit: 5 blocks per tick, every 1 second
- Public API uses `core.hash_node_position()` format
- Internal storage uses base64-encoded "x_y_z" format
- All callbacks receive Luanti standard hashes
- No more "ignore" node failures (mapblocks are atomic)
- Worker functions should be simplified (no failure handling)

---

## Files Modified (17 files total)

- README.md (major documentation overhaul)
- shepherd.lua (block callbacks, processing loop)
- chunk_utils.lua (hash API refactoring)
- dogs.lua (mapblock size, remove ignore handling)
- label_store.lua (hash conversion)
- init.lua (API updates)
- common_tags.lua (API updates)
- compatibility.lua (API updates)
- gennotify_listener.lua (API updates)
- labels.lua (API updates)
- mapgen_env.lua (API updates)
- mapgen_scanners.lua (API updates)
- mod.conf (description update)
- sizes.lua (API updates)
- tags.lua (API updates)
- units.lua (API updates)
- utils.lua (API updates)

---

## Expected Result

- 17 files changed
- Approximately 417 insertions(+), 709 deletions(-)
- Clean migration from mapchunk to mapblock architecture
- Public API uses standard Luanti hashes
- Internal storage format hidden from public API
- Documentation accurately reflects new architecture
