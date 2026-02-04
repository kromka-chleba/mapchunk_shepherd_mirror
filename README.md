Mapchunk Shepherd
=================

A Minetest mod for tracking, labeling, and modifying mapchunks based on player movement and mapgen events.

Authors of source code
----------------------
Jan Wielkiewicz (GPLv3+)

## General idea

The Mapchunk Shepherd is a system responsible for:
* Tracking player movement to discover and label areas of the map
* Assigning labels to mapchunks based on their content or properties
* Dynamically modifying mapchunks using workers

## Features
* Uses Voxel Manipulator for efficient node operations
* Dynamic modification of the map based on labels
* Workers can be registered and unregistered on the fly (unlike ABMs and LBMs)
* Label once, modify multiple times using the same label data
* Can process mapchunks that are loaded but far from players (unlike ABMs)
* Only processes specific mapchunks with matching labels (more targeted than ABMs and LBMs)
* Supports mapgen-time labeling via decoration/biome detection
* Database versioning and compatibility checking

## Terminology
* Mapblock:
Usually a 16x16x16 cubic piece of the map.

* Chunk size:
Number of mapblocks one mapchunk has along each of its axes, by default it is 5.

* Mapchunk:
A cubic piece of map consisting of mapblocks. Mapchunk has a side of N mapblocks where N is equal to chunk size.
By default a mapchunk has a side of 80 (16 * 5).

* Mapchunk offset:
Is defined as -16 * math.floor(chunk_size / 2) so by default -32.
It is the number of nodes by which each mapchunk was shifted relatively to x = 0, y = 0, z = 0 position of the map.
This means the beginning of the first chunk is not at x = 0, y = 0, z = 0 but at x = -32, y = -32, z = -32 (when chunk_size = 5).
Apparently Minetest does it this way so players spawn at the center of a mapchunk and not at the edge.

* Player tracker:
The facility responsible for tracking each player and loading neighboring mapchunks into the system.
The tracker runs periodically (every 10 seconds by default) and checks loaded mapchunks in the player's neighborhood,
adding them to the work queue if they match any registered worker's requirements.

* Neighborhood:
A cuboid space around a player consisting of whole mapchunks including the mapchunk the player is in.
The neighborhood size is determined by the viewing_range setting multiplied by 2.

* Label:
A string tag combined with a timestamp assigned to a mapchunk.
It describes the contents or properties of the chunk, e.g. "has_trees" or "worker_failed".
Labels are stored in Minetest's mod storage using minetest.serialize, with each label containing
a tag (string) and a timestamp (integer) representing the game time when it was created/modified.
The number of possible labels per mapchunk is virtually unlimited.
Labels must be registered using ms.tag.register() before use.

* Scanner:
Not currently implemented in the mod. Previously referred to Voxel Manipulator-based mapchunk scanners.
Use mapgen scanners (biome/decoration finders) or workers for mapchunk analysis instead.

* Mapgen Scanner (Biome/Decoration Finder):
Finds mapchunks that contain given mapgen biomes or decorations and adds labels to the mapchunks.
Uses minetest.register_on_generated to label mapchunks during generation.
More efficient than post-generation scanning because it uses mapgen data directly.
Use cases include finding surface chunks by detecting surface-only decorations or specific biomes.

* Worker:
A Voxel Manipulator-based function that modifies mapchunks based on their labels.
Workers are registered with ms.worker.new() and can specify:
  - needed_labels: labels that must all be present
  - has_one_of: at least one of these labels must be present
  - work_every: time interval (in game seconds) between re-processing the same chunk
  - rework_labels: labels to check timestamps for when determining if work_every has elapsed
  - chance: probability of replacement (0.0 to 1.0)
  - catch_up: whether to increase chance based on missed work cycles
For example, it can replace trees on mapchunks having the "has_trees" label with cotton candy trees
and replace the label with "has_candy_trees".

* Tracked mapchunk:
A mapchunk that was discovered in the neighborhood of a player and is being monitored by the shepherd system.
Tracking happens automatically as players explore the world.

* Mapchunk hash:
Is the encoded position of the origin (minimal corner) of a mapchunk that serves as the mapchunk's ID.
It is obtained using ms.hash(coords) which encodes the position as a base64 string.
This format is compatible with mod storage (unlike raw minetest.hash_node_position which had issues).

## API Overview

### Registering Tags
Tags must be registered before use:
```lua
mapchunk_shepherd.tag.register("my_custom_tag")
```

### Creating Workers
Workers are the primary way to modify mapchunks:
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
To label mapchunks during generation:
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
* `/shepherd_status` - Shows shepherd statistics (tracked chunks, work queue, worker timing)
* `/chunk_labels` - Shows labels of the mapchunk where the player is standing

## Database and Compatibility

The mod uses a versioned database format stored in mod storage. It includes:
* Database version tracking for future upgrades
* Chunksize validation to prevent data corruption
* Automatic initialization for new worlds

**Important:** Changing the chunksize setting after world creation will prevent the mod from starting
to avoid data corruption. You must delete the mod storage or restore the original chunksize.

* Work queue:
Is the list of mapchunks (mapchunk hashes) that wait for being processed by workers.
The player tracker checks neighboring loaded mapchunks and adds them to the work queue if they match worker requirements.
Workers can define "needed_labels" and "has_one_of" to filter which mapchunks they process.
Workers can also define "work_every" to specify how often (in game time) they should re-process the same chunk.
For example a worker replacing spring soil with winter soil will only pick up chunks having the "has_spring_soil"
label and replace the label with "has_winter_soil".
Workers replace nodes on these mapchunks and assign/remove specific labels.

* Failed worker:
Sometimes a worker can fail, usually when the mapchunk contains "ignore" nodes.
If a worker fails, it returns a "worker_failed" label which is assigned to the mapchunk.
The player tracker will retry failed chunks when they become loaded again.
