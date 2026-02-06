Mapchunk Shepherd
=================

A Luanti mod for tracking, labeling, and modifying mapblocks based on Luanti's block activation system.

Authors of source code
----------------------
Jan Wielkiewicz (GPLv3+)

## General idea

The Mapchunk Shepherd is a system responsible for:
* Using Luanti's block callbacks to discover loaded and active mapblocks
* Assigning labels to mapblocks based on their content or properties
* Dynamically modifying mapblocks using workers

## Features
* Uses Voxel Manipulator for efficient node operations on 16x16x16 mapblocks
* Dynamic modification of the map based on labels
* Workers can be registered and unregistered on the fly (unlike ABMs and LBMs)
* Label once, modify multiple times using the same label data
* Prioritizes active blocks (close to players) over loaded blocks (far from players)
* Only processes specific mapblocks with matching labels (more targeted than ABMs and LBMs)
* Supports mapgen-time labeling via decoration/biome detection
* Database versioning and compatibility checking
* Uses Luanti's standard core.hash_node_position() for public API

## Terminology
* Mapblock:
A 16x16x16 cubic piece of the map (fixed size in Luanti).

* Active block:
A mapblock that is close to a player (within the active_block_range). These blocks receive higher priority in the work queue.

* Loaded block:
A mapblock that is loaded in memory but may be far from players. These blocks receive lower priority than active blocks.

* Block queue system:
The work queue maintains two priority levels:
  1. Active blocks (high priority) - processed first, as they're near players
  2. Loaded blocks (low priority) - processed after active blocks
This ensures that changes near players happen faster than changes far away.

* Block callbacks:
Luanti provides four callbacks for tracking blocks:
  - core.register_on_block_activated(function(blockpos)) - Block becomes active (player nearby)
  - core.register_on_block_loaded(function(blockpos)) - Block loaded into memory
  - core.register_on_block_deactivated(function(blockpos_list)) - Block no longer active
  - core.register_on_block_unloaded(function(blockpos_list)) - Block unloaded from memory

The shepherd uses these callbacks to automatically discover blocks without needing a player tracker loop.

* Label:
A string tag combined with a timestamp assigned to a mapblock.
It describes the contents or properties of the block, e.g. "has_trees" or "worker_failed".
Labels are stored in Luanti's mod storage using core.serialize, with each label containing
a tag (string) and a timestamp (integer) representing the game time when it was created/modified.
The number of possible labels per mapblock is virtually unlimited.
Labels must be registered using ms.tag.register() before use.

* Scanner:
Not currently implemented in the mod. Previously referred to Voxel Manipulator-based mapblock scanners.
Use mapgen scanners (biome/decoration finders) or workers for mapblock analysis instead.

* Mapgen Scanner (Biome/Decoration Finder):
Finds mapblocks that contain given mapgen biomes or decorations and adds labels to the mapblocks.
Uses core.register_on_generated to label mapblocks during generation.
More efficient than post-generation scanning because it uses mapgen data directly.
Use cases include finding surface blocks by detecting surface-only decorations or specific biomes.

* Worker:
A Voxel Manipulator-based function that modifies mapblocks based on their labels.
Workers are registered with ms.worker.new() and can specify:
  - needed_labels: labels that must all be present
  - has_one_of: at least one of these labels must be present
  - work_every: time interval (in game seconds) between re-processing the same block
  - rework_labels: labels to check timestamps for when determining if work_every has elapsed
  - chance: probability of replacement (0.0 to 1.0)
  - catch_up: whether to increase chance based on missed work cycles
For example, it can replace trees on mapblocks having the "has_trees" label with cotton candy trees
and replace the label with "has_candy_trees".

* Tracked mapblock:
A mapblock that was discovered through block callbacks and is being monitored by the shepherd system.
Tracking happens automatically as blocks are loaded and activated by the engine.

* Mapblock hash:
The public API uses Luanti's standard core.hash_node_position(blockpos) to identify mapblocks.
Internally, the mod uses a different hash format for storage compatibility, but this is never
exposed to users.

## API Overview

### Registering Tags
Tags must be registered before use:
```lua
mapchunk_shepherd.tag.register("my_custom_tag")
```

### Creating Workers
Workers are the primary way to modify mapblocks:
```lua
local worker = mapchunk_shepherd.worker.new({
    name = "my_worker",
    fun = my_worker_function,
    needed_labels = {"label1", "label2"},  -- All must be present
    has_one_of = {"label3", "label4"},      -- At least one must be present
    work_every = 3600,                      -- Re-run every hour (game time)
    rework_labels = {"label1"},             -- Check these labels for timing
    chance = 0.5,                           -- 50% replacement chance
})
worker:register()
```

### Creating Biome/Decoration Finders
To label mapblocks during generation:
```lua
mapchunk_shepherd.create_biome_finder({
    biome_list = {"grassland", "forest"},
    add_labels = {"has_grass_biome"},
})

mapchunk_shepherd.create_deco_finder({
    deco_list = {
        {name = "default:grass_1", schematic = nil},
    },
    add_labels = {"has_surface_grass"},
})
```

### Helper Functions for Workers
The mod provides several helper functions for creating common worker patterns:
* `ms.create_simple_replacer(args)` - Replace nodes A with nodes B
* `ms.create_param2_aware_replacer(args)` - Replace based on param2 values
* `ms.create_light_aware_replacer(args)` - Replace based on light levels
* `ms.create_neighbor_aware_replacer(args)` - Replace based on neighboring nodes
* `ms.create_light_aware_top_placer(args)` - Place nodes on top of other nodes

### Chat Commands
* `/shepherd_status` - Shows shepherd statistics (tracked blocks, work queue, active/loaded blocks, worker timing)
* `/block_labels` - Shows labels of the mapblock where the player is standing

## Database and Compatibility

The mod uses a versioned database format stored in mod storage. It includes:
* Database version tracking for future upgrades
* Automatic initialization for new worlds
* Uses Luanti's standard hash format (core.hash_node_position) for the public API
* Internal storage uses a private hash format for compatibility

## Work Queue and Priority System

The work queue operates in two priority tiers to optimize performance:

1. **Active Blocks (High Priority)**: Blocks close to players that need immediate attention.
   These are processed first to ensure visible changes happen quickly.

2. **Loaded Blocks (Low Priority)**: Blocks loaded in memory but far from players.
   These are processed after all active blocks to avoid impacting gameplay.

When a block is activated (player moves nearby), it's automatically promoted to high priority.
When a block is deactivated (player moves away), it drops back to low priority.
This ensures the shepherd focuses computational resources where players can see the results.

Workers can define "needed_labels" and "has_one_of" to filter which mapblocks they process.
Workers can also define "work_every" to specify how often (in game time) they should re-process the same block.
For example a worker replacing spring soil with winter soil will only pick up blocks having the "has_spring_soil"
label and replace the label with "has_winter_soil".
Workers replace nodes on these mapblocks and assign/remove specific labels.

* Failed worker:
Sometimes a worker can fail, usually when the mapblock contains "ignore" nodes.
If a worker fails, it returns a "worker_failed" label which is assigned to the mapblock.
The shepherd will retry failed blocks when they become active or loaded again.
