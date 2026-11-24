# Writes the greeting to the store.
{ pkgs ? import <nixpkgs> {} }:

let
  greeting = "hello from Glimt";
  count = 3;
in
pkgs.writeText "preview.txt" greeting
