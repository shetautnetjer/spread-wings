pub(crate) mod store;
pub(crate) use crate::store::Store;

pub(crate) struct Pair<T>(pub T, pub T);
pub struct Unit;
pub union Bits { a: u32, b: f32 }
pub(crate) enum Mode<T> { On(T), Off }
pub unsafe trait Sink<T>: Send where T: Clone {
    fn put(&mut self, item: T);
    fn flush(&mut self) {}
}
pub type Shared<T> = std::sync::Arc<T>;

impl<T: Clone> Sink<T> for Pair<T> {
    fn put(&mut self, item: T) { self.0 = item; }
}

impl<T> Pair<T> {
    pub(crate) const fn new(a: T, b: T) -> Self { Pair(a, b) }
    pub fn len(&self) -> usize { 2 }
    pub fn twice(&self) -> usize { self.len() * 2 }
    pub fn inner(&self) -> usize { self.0.len() }
}

pub(crate) fn total<T>(items: &[T], extra: usize) -> usize where T: Clone {
    fn helper(n: usize) -> usize { n }
    let v: Vec<u8> = Vec::new();
    let p = Pair::<u8>::new(1, 2);
    LOGGER.put(1);
    helper(items.len()) + new_count() + extra
}

pub extern "C" fn new_count() -> usize { 0 }

pub fn only_in_rust() {}

fn len() -> usize { 0 }
fn flush() {}

pub fn drive(s: &mut Store) {
    s.flush();
    flush();
    len();
}
