import { Store, load } from "./store";

export function makeStore(): Store {
  load("x");
  return new Store();
}
