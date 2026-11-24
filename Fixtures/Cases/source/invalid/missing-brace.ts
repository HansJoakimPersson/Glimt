interface Item { id: number; title: string }

export function titles(items: Item[]): string[] {
  return items.map((item) => {
    return item.title;
  ;
