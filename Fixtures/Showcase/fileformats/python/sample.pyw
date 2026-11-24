"""Small Tk window for the desktop helper."""

import tkinter as tk

def make_window() -> tk.Tk:
    window = tk.Tk()
    window.title("Glimt")
    return window
