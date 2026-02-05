# Exile mod: Mapblock shepherd
=============================

Tracks mapblocks players visited and stores info about them.

Authors of source code
----------------------
Jan Wielkiewicz (GPLv3+)

## General idea

The Mapblock Shepherd is a system responsible for:
* Using Luanti's block callback system to track loaded and active mapblocks
* Assigning labels to pieces of the map (mapblocks)
* Modifying/updating specific pieces of the map

## Features
* Uses the Voxel Manipulator so should be pretty fast
* Dynamic modification of the map
* Workers and scanners can be unregistered and registered on the fly (unlike ABMs and LBMs)
* Scan once, modify multiple times
* Uses Luanti's block callback system to track loaded and active blocks
* Processes active blocks (closer to players) before loaded blocks
* Unlike ABMs and LBMs, processes/scans only specific blocks (with specific labels)

## Terminology
* Mapblock:
A 16x16x16 cubic piece of the map. This is the primary unit of processing.

* Label:
A string assigned to a mapblock that describes its contents, e.g. "has_trees" or "has_diamonds".
It is stored in Minetest's mod storage, saved on the disk separately for each world.
Labels are stored in a string using minetest.serialize so the number of possible labels is virtually unlimited.

* Scanner:
A Voxel Manipulator that scans a mapblock for certain nodes and assigns or removes labels accordingly.
For example a scanner could search for trees and assign the "has_trees" label.

* Mapgen "Scanner" (Deco Finder):
Finds mapblocks that contain given mapgen decorations and adds labels to the mapblocks.
It uses minetest.register_on_generated and gennotify so labels are added during mapblock generation.
One good use case is for example finding surface blocks by finding surface-only decorations.
Doesn't use Voxel Manip and is more efficient for finding decorations than a scanner.

* Worker:
A Voxel Manipulator that modifies previously scanned mapblocks.
For example it can replace trees on mapblocks having the "has_trees" label with cotton candy trees and replace the label with "has_candy_trees".

* Active block:
A mapblock that is within active_block_range of a player. Active blocks run game logic (ABMs, node timers, etc.)
and are processed first by the shepherd as they are visible to players.

* Loaded block:
A mapblock that is loaded in memory. All active blocks are also loaded, but not all loaded blocks are active.
Loaded blocks are processed after active blocks.

* Mapblock hash:
Is the hashed position of the mapblock that serves as the mapblock's ID.
Uses Luanti's standard hash format from `core.hash_node_position()`.

* Block Queue:
A queue of mapblocks waiting to be processed by workers. Blocks are added to the queue via Luanti's block callbacks:
  - `core.register_on_block_loaded()` - adds blocks when they're loaded from disk or generated
  - `core.register_on_block_activated()` - marks blocks as active when within active_block_range of a player
  - `core.register_on_block_deactivated()` - demotes blocks from active status
  - `core.register_on_block_unloaded()` - removes blocks from the queue when unloaded from memory

The queue maintains two priority levels: active blocks (close to players) are processed before loaded blocks (in memory but distant).

* Block Processing:
The main processing loop runs every 1 second and processes up to 5 blocks per tick. The process:
  1. Sorts the block queue so active blocks are processed first (they're visible to players)
  2. For each block in the queue (up to the limit):
     - Verifies the block is still loaded using `core.loaded_blocks`
     - Runs eligible workers on the block (based on label requirements)
     - Removes the block from the queue after processing

Workers can define "needed labels" to only process specific blocks. For example, a worker replacing spring soil with 
winter soil will only process blocks with the "has_spring_soil" label and will replace the label with "has_winter_soil".
