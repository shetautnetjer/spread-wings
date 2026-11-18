import { parse, Session } from "./shapes";
import * as shapes from "./shapes";

export function go(s: Session, list: number[]) {
  parse("3");
  s.open();
  shapes.pick(1);
  list.steps();
  steps(2);
}
