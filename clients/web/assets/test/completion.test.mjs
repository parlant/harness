import assert from "node:assert/strict";
import { test } from "node:test";
import { Completer, composerContext, completionEdit } from "../../priv/static/completion.js";

function atEnd(value, explicit = false) {
  return composerContext(value, value.length, explicit);
}

test("commands, directory arguments and inline paths have distinct contexts", () => {
  assert.deepEqual(atEnd("  /c"), { mode: "command", start: 2, end: 4, prefix: "/c" });
  assert.deepEqual(atEnd("/cwd path with spaces/"), {
    mode: "path", kind: "directory", start: 5, end: 22, prefix: "path with spaces/"
  });
  assert.equal(atEnd("/model vendor/id").mode, "argument");
  assert.equal(atEnd("/compact see @clien").kind, "workspace_file");
  assert.equal(atEnd("mention /compact here"), null);
  assert.equal(atEnd("//compact", true), null);
  assert.equal(atEnd("URL https://example.org/"), null);
  assert.equal(atEnd("please see src/fil").kind, "path");
  assert.equal(atEnd("file", true).kind, "path");
  assert.equal(atEnd("/steer !cat src/fil").shell, true);
});

test("completion replaces the whole active token but preserves surrounding text", () => {
  const arg = "/thinking higXX thanks";
  assert.deepEqual(completionEdit(arg, composerContext(arg, 13), { value: "high" }), {
    value: "/thinking high thanks", cursor: 14, chain: false
  });
  const command = "/cwX ./old";
  assert.deepEqual(completionEdit(command, composerContext(command, 3), { value: "/cwd", takesArg: true }), {
    value: "/cwd ./old", cursor: 4, chain: false
  });
});

test("selecting an @ folder preserves the trigger until a file is picked", () => {
  const dir = completionEdit("see @clien", atEnd("see @clien"), { value: "clients/", kind: "dir" });
  assert.deepEqual(dir, { value: "see @clients/", cursor: 13, chain: true });
  assert.deepEqual(completionEdit(dir.value, atEnd(dir.value), { value: "clients/file name.ex", kind: "file" }), {
    value: "see clients/file name.ex", cursor: 24, chain: false
  });
});

test("an async result cannot overwrite a new lookup, a command, or a dismissed editor", () => {
  // Exercise lookup transitions without a DOM layout (covered separately in a browser).
  const requests = [];
  const input = { id: "prompt-input", value: "", selectionStart: 0, selectionEnd: 0 };
  const subject = Object.assign(Object.create(Completer.prototype), {
    input, composer: true, event: "complete_path", items: [],
    meta: { commands: [{ name: "/compact" }] },
    hook: { pushEvent: (_, payload) => requests.push(payload) },
    view: { close() {} },
    setItems(items) { this.items = items; this.selected = 0; }
  });
  const result = (index, value) => ({ ...requests[index], items: [{ value }] });
  const type = value => Object.assign(input, { value, selectionStart: value.length, selectionEnd: value.length });
  globalThis.window = { setTimeout, clearTimeout };
  globalThis.document = { activeElement: input };
  try {
    type("@c");
    subject.update(true);
    type("@cl");
    subject.update(true);
    subject.receive(result(0, "old/"));
    assert.deepEqual(subject.items, []);
    subject.receive(result(1, "clients/"));
    assert.deepEqual(subject.items, [{ value: "clients/" }]);

    type("@cli");
    subject.update(true);
    assert.deepEqual(subject.items, [{ value: "clients/" }]);
    type("/com");
    subject.update();
    subject.receive(result(2, "clients/web/"));
    assert.deepEqual(subject.items.map(item => item.value), ["/compact"]);

    type("/cwd ");
    subject.update(true);
    subject.dismiss();
    subject.receive(result(3, "clients/"));
    assert.deepEqual(subject.items, []);
  } finally {
    delete globalThis.window;
    delete globalThis.document;
  }
});
