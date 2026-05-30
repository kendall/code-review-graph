const std = @import("std");
const builtin = @import("builtin");

/// An enum container.
pub const Color = enum { red, green, blue };

/// A tagged union — its `(enum)` payload must NOT produce a phantom call edge.
pub const Shape = union(enum) {
    circle: f32,
    square: f32,
};

/// A struct with a method.
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn dist(self: Point) i32 {
        return self.x + self.y;
    }
};

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn helper() void {
    const p = Point{ .x = 1, .y = 2 };
    _ = add(1, 2);
    _ = p.dist();
}

pub fn main() void {
    helper();
    std.debug.print("hi\n", .{});
}

test "add works" {
    try std.testing.expect(add(1, 2) == 3);
}
