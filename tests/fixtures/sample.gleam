import gleam/io
import gleam/list.{map}
import gleam/string as str

/// An enum-style custom type with several constructors.
pub type Color {
  Red
  Green
  Blue
}

/// A record-style custom type.
pub type Point {
  Point(x: Int, y: Int)
}

/// An opaque parameterised type.
pub opaque type Wrapper(a) {
  Wrapper(value: a)
}

/// A type alias.
pub type Meters =
  Int

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

fn helper() -> Int {
  let r = add(1, 2)
  io.println("hi")
  list.map([1, 2], fn(x) { x + 1 })
  r
}

pub fn main() {
  let _ = helper()
}

pub fn add_test() {
  let _ = add(1, 2)
}
