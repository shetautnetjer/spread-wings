// Definitions spelled in ways a list of shapes misses: read by node kind.
export const parse = (text: string, strict?: boolean): number[] =>
  text.split(",").map(Number);

export const load = async <T,>(path: string): Promise<T> => {
  return JSON.parse(path) as T;
};

export function* steps(n: number) {
  yield n;
}

export function pick(a: string): string;
export function pick(a: number): number;
export function pick(a: any): any {
  return a;
}

declare function ambient(x: number): string;

export const useStore = create((set: unknown) => ({ n: 0 }));

const run = promisify(load);
const unused = promisify(load);

export interface Port {
  close(): Promise<void>;
  readonly onData: (chunk: string) => void;
  readonly label: string;
}

export abstract class Session implements Port {
  readonly label = "s";
  readonly onData = (chunk: string) => this.push(chunk);
  constructor(private readonly id: number, public name: string) {}
  async close(): Promise<void> {
    await run("x");
    this.push("bye");
  }
  protected push(chunk: string): void {}
  abstract open(): void;
  static create(): Session | undefined {
    return undefined;
  }
}

export enum Color { Red, Green }
export type Handler = { handle: (e: Event) => void; name: string };

function push(chunk: string): void {}

export function main(port: Port, items: string[]) {
  port.close();
  items.push("x");
  push("y");
  parse("1,2");
  Session.create();
  only_in_rust();
}
