Mapblock Shepherd Lua API Reference
====================================

Introduction
------------

Mapblock Shepherd is a Luanti mod that provides a system for processing mapblocks
based on labels and scheduling. It allows mods to:

* Label mapblocks with tags during mapgen or runtime
* Schedule processing of mapblocks based on their labels
* Create workers that modify mapblocks with VoxelManipulators
* **Process ALL loaded blocks** (including those far from players), unlike ABMs/LBMs which only process active blocks. Active blocks (near players) are processed first for better responsiveness.
* Access neighboring mapblocks for cross-boundary operations

The mod uses Luanti's block callbacks (`core.register_on_block_loaded`, 
`core.register_on_block_activated`, etc.) to automatically discover and queue
blocks for processing.


Core Namespace
--------------

All API functions are accessed through the `mapchunk_shepherd` global namespace,
typically aliased as `ms` in your code:

```lua
local ms = mapchunk_shepherd
```


Tags
====

Tags are string identifiers that can be assigned to mapblocks as labels.
All tags must be registered before use.

`ms.tag.register(name)`

* Registers a new tag with the given name
* `name`: String, unique identifier for the tag
* Throws an assertion error if:
    * `name` is not a string
    * A tag with this name is already registered
* Example:
  ```lua
  ms.tag.register("has_trees")
  ms.tag.register("needs_processing")
  ```

`ms.tag.check(name)`

* Checks if a tag is registered
* `name`: String, tag name to check
* Returns: Boolean, `true` if registered, `false` otherwise
* Example:
  ```lua
  if ms.tag.check("has_trees") then
      -- Tag exists
  end
  ```

`ms.tag.get_registered()`

* Returns a list of all registered tag names
* Returns: Table (array) of tag name strings
* Example:
  ```lua
  local tags = ms.tag.get_registered()
  for _, tag_name in ipairs(tags) do
      print(tag_name)
  end
  ```


Labels
======

Labels are tag-timestamp pairs attached to mapblocks. Each label consists of
a tag name and a game time timestamp indicating when it was created or last modified.

Label Objects
-------------

`ms.label.new(tag)`

* Creates a new label with the current game time
* `tag`: String, must be a registered tag name
* Returns: Label object
* Throws an assertion error if tag is not registered
* Example:
  ```lua
  local label = ms.label.new("has_trees")
  ```

`ms.label.from_raw(raw)`

* Creates a label from raw storage format
* `raw`: Table in format `{tag_name, timestamp}`
* Returns: Label object
* Used internally for deserialization

`label:format()`

* Formats label for storage
* Returns: Table `{name, timestamp}` suitable for serialization

`label:refresh_timestamp()`

* Updates the label's timestamp to the current game time
* Modifies the label in-place

`label:elapsed_time()`

* Gets time elapsed since label was created/modified
* Returns: Number, game seconds since timestamp

`label:description()`

* Returns a human-readable description of the label
* Returns: String in format `"{tag_name, timestamp}"`
* Used by the `/chunk_labels` command

Label Encoding/Decoding
-----------------------

`ms.label.encode(...)`

* Encodes labels into a serialized string for mod storage
* `...`: One or more label objects (can be a table or unpacked arguments)
* Returns: Serialized string
* Example:
  ```lua
  local label1 = ms.label.new("has_trees")
  local label2 = ms.label.new("needs_water")
  local encoded = ms.label.encode({label1, label2})
  ```

`ms.label.decode(encoded)`

* Decodes a serialized label string from mod storage
* `encoded`: String, serialized label data
* Returns: Table (array) of label objects, or empty table if none
* Example:
  ```lua
  local labels = ms.label.decode(encoded_string)
  ```

Label Utilities
---------------

`ms.get_labels(blockpos)`

* Gets all labels for a mapblock
* `blockpos`: Table `{x, y, z}` in mapblock coordinates
* Returns: Table (array) of label objects
* Example:
  ```lua
  local labels = ms.get_labels({x=0, y=0, z=0})
  for _, label in ipairs(labels) do
      print(label:description())
  end
  ```

`ms.labels.oldest_elapsed_time(labels, tags)`

* Finds the oldest elapsed time among labels matching given tags
* `labels`: Table (array) of label objects
* `tags`: Table (array) of tag name strings to check
* Returns: Number, oldest elapsed time in seconds, or 0 if no matches
* Example:
  ```lua
  local labels = ms.get_labels(blockpos)
  local elapsed = ms.labels.oldest_elapsed_time(labels, {"has_trees", "has_grass"})
  ```


Workers
=======

Workers are functions that process mapblocks based on their labels. They use
VoxelManipulators to modify block contents efficiently.

Worker Objects
--------------

`ms.worker.new(args)`

* Creates a new worker object
* `args`: Table with the following fields:
    * `name`: String, unique worker identifier (required)
    * `fun`: Function, worker function with signature
      `function(pos_min, pos_max, vm_data, chance)` (required)
    * `needed_labels`: Table (array) of tag names that must ALL be present
      (optional)
    * `has_one_of`: Table (array) of tag names, at least ONE must be present
      (optional)
    * `rework_labels`: Table (array) of tag names to check for timing
      (optional)
    * `work_every`: Number, minimum game seconds between re-runs on same block
      (optional)
    * `chance`: Number, probability of replacement (0.0 to 1.0) (optional)
    * `catch_up`: Boolean, whether to increase chance for missed cycles
      (optional)
    * `catch_up_function`: Function, custom catch-up logic (optional)
    * `afterworker`: Function, called after worker completes with signature
      `function(blockpos)` (optional)
* Returns: Worker object, or `nil` if `fun` is not a function
* The worker function should return:
  `labels_to_add, labels_to_remove, light_changed, param2_changed`
* Example:
  ```lua
  local worker = ms.worker.new({
      name = "tree_grower",
      fun = function(pos_min, pos_max, vm_data, chance)
          -- Modify nodes in vm_data.nodes
          return {"has_trees"}, {"needs_trees"}, false, false
      end,
      needed_labels = {"suitable_soil"},
      work_every = 60,
      chance = 0.1
  })
  ```

`worker:register()`

* Registers the worker with the shepherd system
* If already registered, marks workers as changed to trigger reload
* Must be called for the worker to be active

`worker:unregister()`

* Unregisters the worker from the shepherd system
* The worker will no longer process blocks

`worker:run(pos_min, pos_max, vm_data)`

* Runs the worker function on a mapblock
* `pos_min`: Table `{x, y, z}`, minimum node position of mapblock
* `pos_max`: Table `{x, y, z}`, maximum node position of mapblock
* `vm_data`: Table with `{nodes, param2, light}` arrays from VoxelManip
* Returns: `labels_to_add, labels_to_remove, light_changed, param2_changed`
* Automatically applies catch-up logic if enabled
* Note: Usually called by the shepherd system, not directly by mods

`worker:run_afterworker(blockpos)`

* Runs the afterworker callback if defined
* `blockpos`: Table `{x, y, z}`, mapblock position that was processed
* Called automatically by shepherd after worker completes
* Note: Usually called by the shepherd system, not directly by mods

Worker Helper Functions
-----------------------

`ms.create_simple_replacer(args)`

* Creates a worker function that replaces nodes
* `args`: Table with:
    * `find_replace_pairs`: Table, map of `node_name -> replacement_name`
    * `add_labels`: Table (array), labels to add if nodes were found
    * `remove_labels`: Table (array), labels to remove if nodes were found
    * `not_found_labels`: Table (array), labels to add if no nodes found
    * `not_found_remove`: Table (array), labels to remove if no nodes found
* Returns: Worker function suitable for `ms.worker.new({fun = ...})`
* Checks for `ignore` nodes and returns `{"worker_failed"}` if found
* Example:
  ```lua
  local replacer = ms.create_simple_replacer({
      find_replace_pairs = {
          ["default:dirt"] = "default:dirt_with_grass"
      },
      add_labels = {"has_grass"},
      remove_labels = {"needs_grass"}
  })
  
  ms.worker.new({
      name = "grass_grower",
      fun = replacer,
      needed_labels = {"suitable_climate"}
  }):register()
  ```

`ms.create_param2_aware_replacer(args)`

* Creates a worker function that replaces nodes based on param2 values
* Similar to `create_simple_replacer` but checks param2
* `args`: Same as `create_simple_replacer`, plus:
    * `find_ids`: Table, map of `node_name -> param2_value_to_find`
* Returns: Worker function
* Only replaces nodes that match both content_id and param2 value

`ms.create_light_aware_replacer(args)`

* Creates a worker function that replaces nodes based on light levels
* `args`: Same as `create_simple_replacer`, plus:
    * `higher_than`: Number, minimum light level (exclusive)
    * `lower_than`: Number, maximum light level (exclusive)
* Returns: Worker function
* Only replaces nodes within the specified light level range
* Example:
  ```lua
  local dark_replacer = ms.create_light_aware_replacer({
      find_replace_pairs = {
          ["default:stone"] = "default:stone_with_mese"
      },
      higher_than = 0,
      lower_than = 7,  -- Dark areas only
      add_labels = {"has_mese"}
  })
  ```

`ms.create_light_aware_top_placer(args)`

* Creates a worker function that places nodes on top of other nodes
* Places on nodes that have air above and meet light requirements
* `args`:
    * `find_replace_pairs`: Table, map of `base_node -> node_to_place_above`
    * `higher_than`: Number, minimum light level
    * `lower_than`: Number, maximum light level
    * `add_labels`: Table (array), labels to add if placement occurred
    * `remove_labels`: Table (array), labels to remove if placement occurred
    * `not_found_labels`: Table (array), labels if no placement
    * `not_found_remove`: Table (array), labels to remove if no placement
* Returns: Worker function
* Useful for growing plants, crystals, or other surface features

`ms.create_neighbor_aware_replacer(args)`

* Creates a worker function that only replaces nodes near specific neighbors
* `args`: Same as `create_simple_replacer`, plus:
    * `neighbors`: Table (array), node names that must be adjacent
* Returns: Worker function
* Checks all 6 orthogonal neighbors before replacement
* Example:
  ```lua
  local spreader = ms.create_neighbor_aware_replacer({
      find_replace_pairs = {
          ["default:dirt"] = "default:dirt_with_grass"
      },
      neighbors = {"default:dirt_with_grass"},  -- Must be next to grass
      add_labels = {"grass_spread"}
  })
  ```

`ms.remove_worker(name)`

* Removes a worker by name from the shepherd system
* `name`: String, worker name
* Marks workers as changed to trigger reload


Mapgen Scanners
===============

Mapgen scanners label mapblocks during world generation based on biomes or
decorations. They are more efficient than post-generation scanning.

`ms.create_biome_finder(args)`

* Creates a biome finder that labels mapblocks during mapgen
* `args`: Table with:
    * `biome_list`: Table (array), biome names to detect
    * `add_labels`: Table (array), labels to add when biome is found
    * `remove_labels`: Table (array), labels to remove when biome is found
* Note: Currently applies labels to ALL mapblocks in a mapchunk if the biome
  is found anywhere in that mapchunk (typically 5x5x5 mapblocks)
* Example:
  ```lua
  ms.create_biome_finder({
      biome_list = {"desert", "desert_stone"},
      add_labels = {"is_desert"},
      remove_labels = {"needs_scanning"}
  })
  ```

`ms.create_deco_finder(args)`

* Creates a decoration finder that labels mapblocks during mapgen
* `args`: Table with:
    * `deco_list`: Table (array) of decoration definitions, each with:
        * `name`: String, decoration name
        * `schematic`: String, path to schematic file (optional)
        * `flags`: String or table, placement flags like "place_center_x"
        * `rotation`: String, rotation value "0", "90", "180", "270"
        * `place_offset_y`: Number, Y offset for placement
    * `add_labels`: Table (array), labels to add to mapblocks with decoration
    * `remove_labels`: Table (array), labels to remove from those mapblocks
* Correctly handles schematic rotations and centering flags to label all
  mapblocks that may contain parts of multi-node decorations
* Example:
  ```lua
  ms.create_deco_finder({
      deco_list = {
          {name = "default:tree", schematic = "path/to/tree.mts"}
      },
      add_labels = {"has_trees"},
      remove_labels = {"treeless"}
  })
  ```


Block Neighborhood
==================

The block neighborhood system allows workers to access neighboring mapblocks
for operations that cross block boundaries. It provides lazy loading and
caching of neighbor VoxelManipulators.

`ms.block_neighborhood.create(primary_blockpos, primary_vm_data)`

* Creates a neighborhood accessor for a mapblock and its neighbors
* `primary_blockpos`: Table `{x, y, z}`, the focal mapblock position
* `primary_vm_data`: Table with `{nodes, param2, light}` arrays
* Returns: BlockNeighborhood object
* Example:
  ```lua
  local neighborhood = ms.block_neighborhood.create(
      blockpos,
      {nodes = node_array, param2 = param2_array, light = light_array}
  )
  ```

`neighborhood:read_node(world_pos)`

* Reads a node at a world position, loading neighbors as needed
* `world_pos`: Table `{x, y, z}`, world position (not blockpos)
* Returns: Node content ID, or `nil` if position invalid
* Automatically loads neighboring blocks on first access

`neighborhood:write_node(world_pos, node_id)`

* Writes a node at a world position, loading neighbors as needed
* `world_pos`: Table `{x, y, z}`, world position
* `node_id`: Number, node content ID to write
* Returns: Boolean, `true` if successful
* Marks neighboring blocks as dirty for later flushing

`neighborhood:read_param2(world_pos)`

* Reads param2 at a world position
* `world_pos`: Table `{x, y, z}`, world position
* Returns: Number, param2 value, or `nil` if invalid

`neighborhood:write_param2(world_pos, param2)`

* Writes param2 at a world position
* `world_pos`: Table `{x, y, z}`, world position
* `param2`: Number, param2 value to write
* Returns: Boolean, `true` if successful

`neighborhood:read_light(world_pos)`

* Reads light level at a world position
* `world_pos`: Table `{x, y, z}`, world position
* Returns: Number, light value, or `nil` if invalid

`neighborhood:write_light(world_pos, light)`

* Writes light level at a world position
* `world_pos`: Table `{x, y, z}`, world position
* `light`: Number, light value to write
* Returns: Boolean, `true` if successful

`neighborhood:get_adjacent_positions(center_pos)`

* Gets the 6 orthogonally adjacent positions
* `center_pos`: Table `{x, y, z}`, world position
* Returns: Table (array) of 6 position vectors (+X, -X, +Y, -Y, +Z, -Z)
* Useful for spread mechanics, particle spawning, etc.

`neighborhood:commit_all()`

* Flushes all modified peripheral blocks back to the map
* Returns: Number, count of blocks flushed
* Called automatically at end of processing round
* Usually not needed to call manually

`ms.block_neighborhood.wrap_worker_function(worker_fn, needs_neighbors)`

* Wraps a worker function to automatically provide neighborhood access
* `worker_fn`: Function with signature 
  `function(pos_min, pos_max, neighborhood, chance)`
* `needs_neighbors`: Boolean, whether this worker accesses neighbors
* Returns: Wrapped function suitable for `ms.worker.new({fun = ...})`
* Example:
  ```lua
  local worker_fn = function(pos_min, pos_max, neighborhood, chance)
      -- Can now use neighborhood:read_node(), etc.
      local node_above = neighborhood:read_node(
          vector.add(pos_min, {x=0, y=17, z=0})  -- Outside this mapblock
      )
      return {}, {}, false, false
  end
  
  local wrapped = ms.block_neighborhood.wrap_worker_function(worker_fn, true)
  ms.worker.new({
      name = "cross_boundary_worker",
      fun = wrapped
  }):register()
  ```

`ms.block_neighborhood.get_cache_stats()`

* Gets statistics about the global VM cache
* Returns: Table with:
    * `count`: Number of blocks currently cached
    * `memory_estimate`: Approximate memory usage in KB
* Useful for monitoring cache effectiveness


Utility Functions
=================

Coordinate Conversion
--------------------

`ms.units.node_to_mapblock(pos)`

* Converts node position to mapblock position (floating point)
* `pos`: Table `{x, y, z}`, node position
* Returns: Table `{x, y, z}`, mapblock position (may have decimals)

`ms.units.mapblock_to_node(mapblock_pos)`

* Converts mapblock position to node position (origin corner)
* `mapblock_pos`: Table `{x, y, z}`, mapblock position
* Returns: Table `{x, y, z}`, node position of mapblock corner

`ms.units.mapblock_coords(pos)`

* Gets mapblock coordinates from a node position
* `pos`: Table `{x, y, z}`, node position
* Returns: Table `{x, y, z}`, integer mapblock coordinates
* Most commonly used conversion function

`ms.units.mapblock_origin(pos)`

* Gets origin node position of the mapblock containing given position
* `pos`: Table `{x, y, z}`, node position
* Returns: Table `{x, y, z}`, node position of mapblock corner

Block Utilities
---------------

`ms.mapblock_hash(pos)`

* Computes a hash for a mapblock position
* `pos`: Table `{x, y, z}`, mapblock position
* Returns: Number, hash value for internal use
* Note: This is the internal hash format, not Luanti's `hash_node_position`

`ms.mapblock_pos_to_node(blockpos)`

* Converts mapblock position to its minimum node position
* `blockpos`: Table `{x, y, z}`, mapblock position
* Returns: Table `{x, y, z}`, minimum node position

`ms.mapblock_min_max(blockpos)`

* Gets minimum and maximum node positions for a mapblock
* `blockpos`: Table `{x, y, z}`, mapblock position
* Returns: Two tables: `min_pos {x, y, z}`, `max_pos {x, y, z}`
* Example:
  ```lua
  local min_pos, max_pos = ms.mapblock_min_max({x=0, y=0, z=0})
  -- min_pos = {x=0, y=0, z=0}
  -- max_pos = {x=15, y=15, z=15}
  ```

`ms.block_side()`

* Returns the side length of a mapblock in nodes
* Returns: Number, always 16 for Luanti
* Useful for array indexing calculations

Block Timing
------------

`ms.save_time(blockpos)`

* Saves the current game time for a mapblock
* `blockpos`: Table `{x, y, z}`, mapblock position
* Used internally to track when blocks were last modified

`ms.reset_time(blockpos)`

* Resets the stored time for a mapblock to 0
* `blockpos`: Table `{x, y, z}`, mapblock position

`ms.time_since_last_change(blockpos)`

* Gets time elapsed since block was last modified
* `blockpos`: Table `{x, y, z}`, mapblock position
* Returns: Number, game seconds since last change, or 0 if never modified

Storage
-------

`ms.get_storage_key(blockpos)`

* Generates a storage key string for a mapblock
* `blockpos`: Table `{x, y, z}`, mapblock position
* Returns: String, key suitable for mod storage
* Used internally by label storage system

Other Utilities
--------------

`ms.unpack_args(...)`

* Unpacks arguments, handling both table and varargs
* `...`: Either a table or multiple arguments
* Returns: Table (array) of arguments
* Helper function for internal use

`ms.tracked_block_counter()`

* Returns the number of mapblocks being tracked with labels
* Returns: Number, count of tracked blocks
* Useful for monitoring system performance

`ms.placeholder_id_pairs()`

* Returns a table of placeholder node IDs
* Returns: Table, internal placeholder mappings
* Used by worker helper functions

`ms.placeholder_id_finder_pairs()`

* Returns placeholder node IDs for finder functions
* Returns: Table, internal placeholder mappings
* Used by worker helper functions


Examples
========

Basic Worker Example
-------------------

```lua
local ms = mapchunk_shepherd

-- Register tags
ms.tag.register("has_dirt")
ms.tag.register("has_grass")

-- Create and register a worker
local grass_grower = ms.worker.new({
    name = "grass_grower",
    fun = ms.create_simple_replacer({
        find_replace_pairs = {
            ["default:dirt"] = "default:dirt_with_grass"
        },
        add_labels = {"has_grass"},
        remove_labels = {"has_dirt"}
    }),
    needed_labels = {"has_dirt"},
    work_every = 120,  -- Every 2 minutes
    chance = 0.5
})
grass_grower:register()
```

Mapgen Scanner Example
---------------------

```lua
local ms = mapchunk_shepherd

-- Register tag
ms.tag.register("desert_surface")

-- Find desert biomes during mapgen
ms.create_biome_finder({
    biome_list = {"desert", "desert_stone"},
    add_labels = {"desert_surface"}
})
```

Neighborhood Access Example
---------------------------

```lua
local ms = mapchunk_shepherd
local bn = ms.block_neighborhood

ms.tag.register("moisture_spread")

local moisture_spreader = function(pos_min, pos_max, neighborhood, chance)
    -- Read nodes from neighboring blocks
    for x = pos_min.x, pos_max.x do
        for z = pos_min.z, pos_max.z do
            local pos = {x=x, y=pos_min.y, z=z}
            local node_id = neighborhood:read_node(pos)
            
            -- Check position above (might be in neighbor block)
            local above_pos = {x=x, y=pos_min.y + 17, z=z}
            local above_id = neighborhood:read_node(above_pos)
            
            -- Modify as needed
        end
    end
    
    return {"moisture_spread"}, {}, false, false
end

local wrapped = bn.wrap_worker_function(moisture_spreader, true)
ms.worker.new({
    name = "moisture_spreader",
    fun = wrapped,
    work_every = 60
}):register()
```


Performance Considerations
==========================

* Mapblocks are processed one at a time to avoid blocking
* Active blocks (near players) are prioritized over other loaded blocks
* The global VM cache is shared across all workers in a processing round
* Cache is cleared when the block queue becomes empty
* VoxelManipulator operations are batched per mapblock for efficiency
* Use `work_every` to limit how often blocks are re-processed
* Use `chance` to make node replacements probabilistic (note: this adds per-node overhead, not reduces it)


Compatibility
=============

The mod includes a compatibility system that checks the database format.
If the format has changed since the last run, it will:

* Log a warning about database format incompatibility
* Prevent the shepherd system from starting
* Preserve existing label data

To reset after a breaking change, delete the mod storage file or use
administrative commands if available.


Chat Commands
=============

The mod provides administrative commands for debugging:

* `/chunk_labels`: Shows labels for the mapblock at the player's position
* `/block_queue`: Shows information about the current processing queue
  (requires modification to expose this feature)

Note: Command availability may vary based on mod configuration.


License
=======

Mapblock Shepherd is licensed under the GNU General Public License v3.0 or later.
See LICENSE.txt for full license text.


See Also
========

* README.md - General mod documentation and usage guide
* Luanti Lua API - https://github.com/minetest/minetest/blob/master/doc/lua_api.md
* Luanti Modding Book - https://rubenwardy.com/minetest_modding_book/
