// Greet each enabled format.
const count = 42;
function greet(label) {
    return `Glimt ${label}: ${count}`;
}

const formats = ["JavaScript", "JSON", "YAML"];
const preview = { name: "Glimt", enabled: true, version: 1 };
for (const format of formats) {
    if (preview.enabled) {
        const message = greet(format);
        // One line per format.
        console.log(message);
    }
}
