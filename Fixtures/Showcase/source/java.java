// Counter with a display label.
class Example {
    int count = 42;
    String label = "Glimt";
}

// Package-private classes need no filename convention.
class PreviewExample {
    static String greeting(String format) {
        return "Hello from Glimt — previewing " + format;
    }
    public static void main(String[] arguments) {
        for (String format : new String[] {"Java", "JSON", "YAML"}) {
            if (!format.isEmpty()) {
                System.out.println(greeting(format));
            }
        }
    }
}
