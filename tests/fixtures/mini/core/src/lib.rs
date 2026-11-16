mod state;

pub use state::Counter;

pub fn start() -> Counter {
    state::new_counter()
}
