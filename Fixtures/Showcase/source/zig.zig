const std = @import("std");

pub fn main() void {
    const answer: u32 = 42;
    std.debug.print("answer: {d}\n", .{answer});
}
