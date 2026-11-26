export enum Mode {
  Fast,
  Safe,
}

export function render(compact: boolean): string {
  return compact ? "c" : "f";
}

export async function load(): Promise<string> {
  return render(true);
}

export function start(): void {
  load();
}
