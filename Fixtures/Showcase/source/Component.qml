import QtQuick

Item {
    id: root
    property int count: 42
    signal activated(string label)

    Text {
        text: "Count: " + root.count
    }
}
