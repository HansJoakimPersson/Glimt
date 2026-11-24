// Greeting model.
interface Item { count: number; label: string }
const item: Item = { count: 42, label: "Glimt" };

const formats: string[] = ["TypeScript", "JSON", "YAML"];
function greeting(value: Item, format: string): string {
    return `Hello from ${value.label} — previewing ${format}`;
}
for (const format of formats) {
    if (item.count > 0) {
        // Skip empty items.
        console.log(greeting(item, format));
    }
}
