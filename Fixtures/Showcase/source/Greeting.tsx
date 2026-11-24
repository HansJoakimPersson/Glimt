type GreetingProps = {
  name: string;
};

export function Greeting({ name }: GreetingProps) {
  const message = `Hello, ${name}`;
  return <h1 className="greeting">{message}</h1>;
}
