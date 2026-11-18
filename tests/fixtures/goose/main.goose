// A two-file Goose program for the Goose scanner.
import std;
import os;
import .shapes;

let UNIT = 2;

struct Box { side: i64 }

fn main() {
    // total_area("not a call: this is a comment")
    let note = "area(1) inside a string is not a call";
    let help = """
        fn fake(x) is text, not a definition
        """;
    print(str(total_area(3), note, help));
    var names: u8[>..] = [];
    names.append("x");
}
