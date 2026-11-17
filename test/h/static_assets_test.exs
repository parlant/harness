defmodule H.StaticAssetsTest do
  use ExUnit.Case, async: true

  @static_dir Path.expand("../../priv/static", __DIR__)

  describe "static asset files and CSP compliance" do
    test "all required static assets exist" do
      for file <- ["index.html", "app.css", "app.js", "transcript.js"] do
        path = Path.join(@static_dir, file)
        assert File.regular?(path), "expected #{path} to exist"
      end
    end

    test "index.html contains no inline scripts, inline styles, or inline event handlers" do
      html = File.read!(Path.join(@static_dir, "index.html"))

      refute Regex.match?(~r/<script(?![^>]*\bsrc=)[^>]*>/i, html)
      refute Regex.match?(~r/<script[^>]*>[^<\s]/i, html)
      refute Regex.match?(~r/\sstyle\s*=/i, html)
      refute Regex.match?(~r/\son[a-z]+\s*=/i, html)
      assert html =~ ~s(<script type="module" src="./app.js"></script>)
      assert html =~ ~s(<link rel="stylesheet" href="./app.css" />)
    end

    test "app.js avoids unsafe DOM sinks and inline style mutations" do
      js = File.read!(Path.join(@static_dir, "app.js"))

      refute js =~ "innerHTML"
      refute js =~ "outerHTML"
      refute js =~ "insertAdjacentHTML"
      refute Regex.match?(~r/\beval\s*\(/, js)
    end
  end

  describe "transcript.js reducer and delta ops" do
    test "applyDocOps and ConversationTranscript pass all unit assertions in Node" do
      transcript_path = Path.join(@static_dir, "transcript.js")

      node_script = """
      import assert from "node:assert/strict";
      import { pathToFileURL } from "node:url";

      const { applyDocOps, ConversationTranscript } = await import(
        pathToFileURL(#{JSON.encode!(transcript_path)}).href
      );

      // 1. applyDocOps: replace and r
      assert.deepEqual(applyDocOps({ a: 1 }, [["replace", { b: 2 }]]), { b: 2 });
      assert.deepEqual(applyDocOps({ a: 1 }, [["r", { c: 3 }]]), { c: 3 });

      // 2. applyDocOps: set (immutable, nested paths, array indices)
      const doc0 = { run: { turns: 1 }, items: ["x", "y"] };
      const doc1 = applyDocOps(doc0, [
        ["set", ["run", "turns"], 2],
        ["set", ["generation", "message", "role"], "assistant"],
        ["set", ["items", 1], "z"]
      ]);
      assert.equal(doc0.run.turns, 1);
      assert.equal(doc0.generation, undefined);
      assert.equal(doc0.items[1], "y");
      assert.equal(doc1.run.turns, 2);
      assert.equal(doc1.generation.message.role, "assistant");
      assert.deepEqual(doc1.items, ["x", "z"]);

      // 3. applyDocOps: append_text (existing and absent)
      const doc2 = applyDocOps(doc1, [
        ["append_text", ["generation", "message", "text"], "Hello"],
        ["append_text", ["generation", "message", "text"], " world"]
      ]);
      assert.equal(doc1.generation.message.text, undefined);
      assert.equal(doc2.generation.message.text, "Hello world");

      // 4. applyDocOps: delete (object key, array element, missing key)
      const doc3 = applyDocOps(doc2, [
        ["delete", ["generation", "message", "role"]],
        ["delete", ["items", 0]],
        ["delete", ["nonexistent", "key"]]
      ]);
      assert.equal(doc2.generation.message.role, "assistant");
      assert.equal(Object.hasOwn(doc3.generation.message, "role"), false);
      assert.deepEqual(doc3.items, ["z"]);

      // 5. Prototype pollution guard
      assert.throws(() => applyDocOps({}, [["set", ["__proto__", "polluted"], true]]));

      // 6. ConversationTranscript: initial snapshot
      const t = new ConversationTranscript({ sessionId: "demo", conversationId: "1" });
      const snap1 = t.applySnapshot({
        version: 1,
        session_id: "demo",
        conversation_id: "1",
        seq: 10,
        before_entry_id: "8",
        entries: [
          { id: "10", conversation_id: "1", kind: "assistant", data: { text: "hi" } },
          { id: "9", conversation_id: "1", kind: "user", data: { text: "yo" } }
        ],
        docs: { live: { run: { turns: 1 } }, inbox: [], agent: { model: "m1" }, usage: {} }
      });
      assert.deepEqual(snap1, { applied: true, gapInserted: false });
      assert.equal(t.seq, 10);
      assert.equal(t.beforeEntryId, "8");
      assert.deepEqual(t.entries.map((e) => e.id), ["9", "10"]);

      // 7. ConversationTranscript: prependOlderPage (order=desc input normalized ascending, deduped)
      const added = t.prependOlderPage(
        [
          { id: "9", conversation_id: "1", kind: "user", data: { text: "yo" } },
          { id: "8", conversation_id: "1", kind: "assistant", data: { text: "older-2" } },
          { id: "7", conversation_id: "1", kind: "user", data: { text: "older-1" } }
        ],
        null
      );
      assert.equal(added, 2);
      assert.equal(t.beforeEntryId, null);
      assert.deepEqual(t.entries.map((e) => e.id), ["7", "8", "9", "10"]);

      // 8. ConversationTranscript: commit + seq deduplication
      assert.equal(
        t.applyCommit({
          version: 1,
          seq: 10,
          appended_entries: [{ id: "99", conversation_id: "1", kind: "user", data: {} }],
          doc_ops: {}
        }),
        false
      );
      assert.equal(
        t.applyCommit({
          version: 1,
          seq: 11,
          appended_entries: [{ id: "11", conversation_id: "1", kind: "user", data: { text: "next" } }],
          doc_ops: {
            live: [["set", ["generation", "message", "text"], ""]],
            usage: [["set", ["total_tokens"], 42]]
          }
        }),
        true
      );
      assert.equal(t.seq, 11);
      assert.deepEqual(t.entries.map((e) => e.id), ["7", "8", "9", "10", "11"]);
      assert.equal(t.docs.usage.total_tokens, 42);

      // 9. ConversationTranscript: ephemeral base_seq guard
      assert.equal(
        t.applyEphemeral({
          version: 1,
          base_seq: 10,
          doc_ops: { live: [["append_text", ["generation", "message", "text"], "STALE"]] }
        }),
        false
      );
      assert.equal(
        t.applyEphemeral({
          version: 1,
          base_seq: 12,
          doc_ops: { live: [["append_text", ["generation", "message", "text"], "FUTURE"]] }
        }),
        false
      );
      assert.equal(
        t.applyEphemeral({
          version: 1,
          base_seq: 11,
          doc_ops: { live: [["append_text", ["generation", "message", "text"], "streamed"]] }
        }),
        true
      );
      assert.equal(t.docs.live.generation.message.text, "streamed");

      // 10. ConversationTranscript: contiguous reconnect snapshot preserves older entries & beforeEntryId
      const snap2 = t.applySnapshot({
        version: 1,
        seq: 15,
        before_entry_id: "10",
        entries: [
          { id: "10", conversation_id: "1", kind: "assistant", data: { text: "hi" } },
          { id: "11", conversation_id: "1", kind: "user", data: { text: "next" } },
          { id: "12", conversation_id: "1", kind: "assistant", data: { text: "done" } }
        ],
        docs: { live: {}, inbox: [], agent: { model: "m1" }, usage: { total_tokens: 100 } }
      });
      assert.deepEqual(snap2, { applied: true, gapInserted: false });
      assert.equal(t.seq, 15);
      assert.equal(t.beforeEntryId, null);
      assert.deepEqual(t.entries.map((e) => e.id), ["7", "8", "9", "10", "11", "12"]);

      // 11. ConversationTranscript: non-contiguous reconnect snapshot inserts gap marker
      const snap3 = t.applySnapshot({
        version: 1,
        seq: 30,
        before_entry_id: "19",
        entries: [
          { id: "20", conversation_id: "1", kind: "user", data: { text: "after gap" } }
        ],
        docs: { live: {}, inbox: [], agent: { model: "m1" }, usage: { total_tokens: 200 } }
      });
      assert.deepEqual(snap3, { applied: true, gapInserted: true });
      assert.equal(t.seq, 30);
      assert.equal(t.beforeEntryId, null);
      assert.deepEqual(
        t.items.map((item) => (item.kind === "gap" ? item : item.id)),
        ["7", "8", "9", "10", "11", "12", { kind: "gap", from_exclusive: "12", to_inclusive: "19" }, "20"]
      );
      """

      {output, status} =
        System.cmd("node", ["--input-type=module", "-e", node_script], stderr_to_stdout: true)

      assert status == 0, "Node test failed:\n#{output}"
    end
  end
end
