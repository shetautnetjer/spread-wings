export class Store {
  get(key: string): string {
    return load(key);
  }
}

export function load(key: string): string {
  return key;
}
