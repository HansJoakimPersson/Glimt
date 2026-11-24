// Whiley
function square(int x) -> (int r)
ensures r >= 0:
    return x * x

method main():
    int y = square(3)
