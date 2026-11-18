pub struct Store { n: usize }

impl Store {
    pub fn flush(&mut self) { self.n = 0; }
}
