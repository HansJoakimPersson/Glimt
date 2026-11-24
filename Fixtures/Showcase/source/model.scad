// A parametric block with a centered through-hole.
$fn = 48;
wall = 3;

module perforated_block(size = 24, depth = 12) {
    difference() {
        cube([size, size, depth], center = true);
        cylinder(h = depth + 1, r = size / 6, center = true);
    }
}

perforated_block();
