// Inbäddade reguljära uttryck
const email = /^[\w.+-]+@[\w-]+\.[\w.]+$/i;
const date = /(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})/u;
console.log(email.test("a@example.test"), date.exec("2026-11-18").groups.year);
