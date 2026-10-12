import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { SITE } from "./helpers.mjs";

// The "Did you mean …?" hint lives in the page's own script; take its functions out of it.
const html = await readFile(SITE + "index.html", "utf8");
const source = html.slice(html.indexOf("var PROVIDERS"), html.indexOf("  function showSuggestion"));
const suggestEmail = new Function(`${source}; return suggestEmail;`)();

test("common provider typos get a suggestion", () => {
  const cases = {
    "a@gmai.com": "a@gmail.com", "x@gmial.com": "x@gmail.com", "x@gamil.com": "x@gmail.com",
    "x@gmal.com": "x@gmail.com", "x@hotmial.com": "x@hotmail.com", "x@hotmal.com": "x@hotmail.com",
    "x@yaho.com": "x@yahoo.com", "x@yahooo.com": "x@yahoo.com", "x@outlok.com": "x@outlook.com",
    "x@iclod.com": "x@icloud.com", "x@gmail.con": "x@gmail.com", "x@gmail.co": "x@gmail.com",
    "x@icloud.cmo": "x@icloud.com",
  };
  for (const [typed, fixed] of Object.entries(cases)) assert.equal(suggestEmail(typed), fixed, typed);
});

test("real addresses are never second-guessed", () => {
  for (const email of ["x@gmail.com", "x@example.co", "x@mycompany.com", "x@bupsy.dev", "x@me.com",
    "x@ma.com", "x@aol.com", "x@yahoo.co.uk", "x@mail.com", "x@gmx.com", "x@ymail.com", "x@email.com", "nope"]) {
    assert.equal(suggestEmail(email), null, email);
  }
});
