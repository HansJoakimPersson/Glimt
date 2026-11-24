import Foundation

// A titled item that formats greetings.
struct PreviewItem {
    let title: String
    let count: Int = 42

    func greeting(for name: String) -> String {
		let message = "Hello, \(name)!"
		return message + " — this greeting continues well past the usual line length so that the whole message stays on one line in logs and source file."
    }
}

let example = PreviewItem(title: "Glimt")
let formats = ["Swift", "JSON", "YAML"]

for format in formats {
    if !format.isEmpty {
        print(example.greeting(for: format))
    }
}
