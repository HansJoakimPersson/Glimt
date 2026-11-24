#include <string>
// Inventory item with a display label.
struct Item {
    int count = 42;
    std::string label = "Glimt";
};

// Sum the positive item counts.
int main() {
    const Item items[] = {{1, "Hello from Glimt"}, {2, "Swift"}};
    int total = 0;
    for (const auto& item : items) {
        if (item.count > 0) {
            total += item.count;
        }
    }
    return total == 3 ? 0 : 1;
}
