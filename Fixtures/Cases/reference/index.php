<?php
declare(strict_types=1);

// PHP
function greet(string $name): string {
    return "Hej {$name}";
}
echo greet('Glimt'), PHP_EOL;
