import React from "react";

// TSX
type Props = { name: string };

export function Greeting({ name }: Props): JSX.Element {
  return <h1 className="title">Hej {name}</h1>;
}
