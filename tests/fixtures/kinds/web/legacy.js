class Cache {
  get(key) { return this.map[key]; }
  static make() { return new Cache(); }
}

const wrap = function (fn) { return fn; };
var twice = (x) => x * 2;

function boot() {
  wrap(twice);
  Cache.make();
}

class Vault {
  #seal() { return 1; }
  unlock() { return this.#seal(); }
}
