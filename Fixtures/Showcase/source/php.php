<?php
// Build the greeting for a name.
function greet(string $name): string {
    return "Hello, {$name}";
}

echo greet('Glimt');
