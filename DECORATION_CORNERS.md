# Decoration Corner Calculation

## Problem

The original `get_corners()` function in `dogs.lua` did not accurately replicate Luanti's decoration placement logic, particularly for schematic decorations with rotation and centering flags. This could cause decoration finders to miss mapblocks that actually contain parts of multi-node decorations.

## Solution

Rewrote `get_corners()` to match the C++ implementation in `src/mapgen/mg_decoration.cpp` from the Luanti engine.

## C++ Algorithm Reference

From `DecoSchematic::generate()` in mg_decoration.cpp:

```cpp
// 1. Apply Y centering/offset
if (flags & DECO_PLACE_CENTER_Y) {
    p.Y -= (schematic->size.Y - 1) / 2;
} else {
    p.Y += place_offset_y;
}

// 2. Determine rotation
Rotation rot = (rotation == ROTATE_RAND) ? 
    (Rotation)pr->range(ROTATE_0, ROTATE_270) : rotation;

// 3. Apply X centering (depends on rotation!)
if (flags & DECO_PLACE_CENTER_X) {
    if (rot == ROTATE_0 || rot == ROTATE_180)
        p.X -= (schematic->size.X - 1) / 2;
    else  // ROTATE_90 or ROTATE_270
        p.Z -= (schematic->size.X - 1) / 2;
}

// 4. Apply Z centering (depends on rotation!)
if (flags & DECO_PLACE_CENTER_Z) {
    if (rot == ROTATE_0 || rot == ROTATE_180)
        p.Z -= (schematic->size.Z - 1) / 2;
    else  // ROTATE_90 or ROTATE_270
        p.X -= (schematic->size.Z - 1) / 2;
}
```

## Key Fixes

### 1. Rotation Handling

**Before**: Rotation was completely ignored
**After**: 
- Handles "0", "90", "180", "270" rotations
- For 90°/270° rotations, X and Z dimensions are effectively swapped
- Centering flags apply to the correct axes after rotation

### 2. Centering Calculations

**Before**: 
```lua
x_offset = math.floor(size.x / 2)  -- Wrong!
y_offset = math.floor(size.y / 2)  -- Wrong!
```

**After**:
```lua
x_offset = -math.floor((size.x - 1) / 2)  -- Matches C++
y_offset = -math.floor((size.y - 1) / 2)  -- Matches C++
```

The difference matters:
- For size=3: old gives 1, new gives -1 (correct)
- For size=4: old gives 2, new gives -1 (correct)
- The negative sign is correct because we're offsetting from the decoration position

### 3. Corner Iteration

**Before**: 
```lua
for x = 0, size.x, size.x do  -- Only gets 0 and size.x (wrong step!)
```

**After**:
```lua
for x = 0, size.x - 1, math.max(1, size.x - 1) do  -- Gets 0 and size.x-1
```

This ensures we get both corners of the bounding box, even for size=1.

### 4. Rotation and Dimension Swapping

For 90°/270° rotations:
- Physical X extent uses Z dimension from schematic
- Physical Z extent uses X dimension from schematic
- Centering calculations account for this swap

Example: 5×3×7 schematic rotated 90°
- Physical size becomes 7×3×5 (X and Z swapped)
- place_center_x applies to Z (using original X size)
- place_center_z applies to X (using original Z size)

## Testing Considerations

To verify the fix works correctly:

1. **Simple decoration** (1×1×1): Should work same as before
2. **Non-centered schematic** (5×3×7): Should cover correct area
3. **Centered schematic** with place_center_x/y/z flags
4. **Rotated schematic** at 90° or 270°
5. **Rotated + centered schematic**: Most complex case

## Impact

This fix ensures that decoration finders correctly identify ALL mapblocks that might contain any part of a multi-node schematic decoration, preventing missed labels and ensuring the shepherd system can properly track decorated areas.
