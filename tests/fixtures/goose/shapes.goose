import std;

extern fn c_helper(x: i64) -> i64;

fn area(side: i64) -> i64 { return side * side * UNIT; }

fn total_area(side: i64) -> i64 {
    fn twice(v: i64) -> i64 {
        return v * 2;
    }
    return twice(area(side)) + c_helper(side);
}
