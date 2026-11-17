import {
  load,
  save,
} from "./store";
export function run() { return load() + save(); }
