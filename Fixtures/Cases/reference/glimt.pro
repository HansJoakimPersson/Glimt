# qmake
TEMPLATE = app
TARGET = glimt
QT += core widgets
SOURCES += main.cpp
macx: LIBS += -framework Cocoa
