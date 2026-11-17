# WTF is Pi Durable — Mario Zechner (Vienna AI Engineering Meetup)

- **Video URL:** https://www.youtube.com/watch?v=EreOxs9Vvrg
- **Title:** Pi Durable - Mario Zechner ("WTF is Pi Durable")
- **Speaker:** Mario Zechner (`@badlogic`, creator of Pi, Earendil)
- **Channel / Event:** Vienna AI Engineering Meetup (https://www.meetup.com/vienna-ai-engineering/events/317187157/)
- **Event Date:** 2026-11-10 (Published 2026-11-15)
- **Duration:** 00:39:16 (2,356 seconds)
- **Audio SHA-256 (`audio.webm`, format 251):** `2e9dcc073edafa218c46b292a6da9475275fdb67600c9cef576523a85675292c`
- **Transcription Tool:** `sayneat --transcribe --language en` (local `sherpa-onnx` Whisper Turbo, 95 speech windows)

> **Event Abstract:**
> Pi the coding agent is built for one human in a terminal: if the process dies, you look at what happened and tell it to continue. But what if you want an agent that lives in Slack for years, talks to many people in parallel, survives the laptop going to sleep or the container being redeployed, and runs on Cloudflare instead of your Mac? That's Pi Durable, the experimental harness Earendil shipped alongside Pi 1.0. Mario will explain in detail WTF it actually is.

---

## Part 1: Edited Study Transcript (Technical Terms Normalized)

Bracketed timestamps correspond to the `sayneat` speech windows in Part 2. Technical terms mangled by raw phonetic ASR (such as *Pi Durable*, *Cloudflare Durable Objects*, *idempotency*, *Termux*, *Hetzner*, *QEMU*, *`pi.generation`*, *`pi.live`*, *Mutative/Immer*, *OpenClaw*, *sycophancy*, *RAG*) are normalized in `[brackets]` or inline for readability; the unmodified `sayneat` ASR output follows in Part 2.

### Introduction & Why Terminal Coding Agents Fail at Durability (`00:00:00` – `00:03:24`)

**[00:00:00]** So yeah, I am on two hours of sleep, as you have noticed. I can't get basic things right anymore. First question: who still reads the code? You liars, you filthy, filthy liars. Nobody's reading the code anymore, so I thought today instead of bringing shitty robots and **[00:00:25]** doing other fun stuff, I'm going to do super fucking boring stuff and show you code. Remember the times when you looked at code? Good times. Remember the times when you wrote the code yourself? Pretty good times too. So I didn't write this, obviously. Didn't write a single line of this except for a bunch of interfaces and types to kind of steer the agent in the direction I want, and then I reviewed it. Out came something called `pi-durable`.

**[00:00:50]** Who knows what Pi is? Okay, a coding agent. A coding agent like Pi or Codex or Claude Code or whatever you have has a problem. And the problem is it's not durably executing its stuff. **[00:01:15]** We're going to learn what that means in a bit. And it might not even durably store the stuff that happened. If you run Claude Code or Pi, a tool is being executed, and you press `Ctrl-C` twice, then that tool call basically never happened. It's not in the storage of this context. Same is true for many coding agents, because in our day-to-day use of coding agents, we don't really care **[00:01:42]** if the process that runs the agent falls over and kills itself and is restarted—you select the session and say "continue", right? That works for us.

That doesn't work if you deploy an agent to a Cloudflare Durable Object. Doesn't work if all of your agents are running on a pesky little phone with a memory limit and a process limit—and I'm going to show you what runs on this later. **[00:02:08]** It doesn't work if you deploy it to a robot with a battery that falls over when the battery is out.

So basically what you want is your agents to restart in case of failure. You need a sort of supervisor that can start the process back up. That can be a Durable Object on Cloudflare or some other serverless stuff. It can be just a supervisor process on the machine that spawns the agent again, whatever. And then the harness running the agent—harness being system prompt, tools, **[00:02:33]** garbage, and connection to the LLM—the harness should be able to resume from where it left off, and it shouldn't have forgotten what it did. No output gets lost, and try your best to reconstruct what's happening.

That is why I built Pi Durable, because it turns out our agents are moving away from our devices. I mean, the LLM already lives in the cloud, but also the agent loop itself, **[00:02:59]** the harness, is probably moving into the cloud as well for reasons. Sam Altman has kind of a point, I guess—he probably has a point that most of our agentic computing is moving to the cloud. So that means you need something that is durable, that is resistant to restarts.

### Pi Durable in Four Sentences: Durable Execution, Storage, Scheduling, Multiplayer (`00:03:24` – `00:05:05`)

**[00:03:24]** Okay, so Pi Durable in four sentences—I totally wrote this myself:
1. It's not a coding agent; it's a library for building agents. And it's written in TypeScript because I hate myself—I'm actually a C person, but it turns out agents are very good with TypeScript, and JavaScript is available pretty much anywhere, including my ESP32 devices now. **[00:03:48]** You can do a lot of shit with JavaScript. Doesn't preclude it being ported to Rust, right? Because we know that's just a prompt away. Or we can even do it in Zig.
2. What it provides you with is **durable execution and storage**. That means if the process kills itself, it can pick up where it left off, and everything that happened until that point was actually durably stored in some form of storage.
3. **[00:04:16]** You also have **scheduling**. Everything within the harness session in Pi Durable is expressed as a **task with phases**, and each phase is basically: record what you're about to do, do the thing (call it an **effect**), and when that returns with a result, persist the result and go to the next phase. We're going to look at what that means in code terms in a bit.
4. **[00:04:41]** All of this is also inherently **single and multiplayer**, which is becoming more important as people realize that sitting in front of a computer talking to an agent all day alone fucking sucks and makes you mad and psychotic.

### Why Event Sourcing Fails for Long-Running Agents (`00:05:05` – `00:08:01`)

**[00:05:05]** Recovery and tracking state once we've killed the process: this is what we talked about earlier. Some stupid coding agent does a thing, the process falls over, and then you reopen the session and type "continue" like a pleb. Suppose you have a Slack agent, a bot in Slack—like OpenClaw or Hermes or whatever—and your instance on which you installed that garbage **[00:05:29]** falls over for some reason because it killed itself. It happens. And then you're like, what the fuck happened? Why doesn't it restart? And if it even restarts, can it pick up from where it left off? Probably not. It also extends to Cloudflare, serverless environments, or my phone, as I said earlier.

The basic principle here is: you have user inputs, you have model streams, you have tools that print stuff out. Whatever happens **[00:05:56]** gets persisted in a **sequentialized commit log**. Basically, it's **not** an event log. It's **not event sourcing**, because that doesn't work for very long-running agents.

What most harnesses do nowadays is: anytime something happens—like I got the first token from the agent—I write it to disk as an event. If I get a thinking token, I write it to disk as an event. If I got the tool call, I write it to disk as an event. If my tool executes and spits out something, I write it to disk as an event. **[00:06:23]** Now you can do this for a coding session that's maybe 3,000 entries in the context (user messages, assistant messages, tool call and execution). You **cannot** do this for a Slack bot that is supposed to live for five years in a handful of channels with thousands of people. So event sourcing is a stupid fucking model for storing long-running agent sessions, and that's why we're not doing that.

**[00:06:47]** Instead, we have **state persistence** through these tasks and through these effects I talked about earlier. And to have those durability guarantees, we need to **serialize every state change** in all of these tasks in sequential order. That sounds scary if you still know what that means: in database terms, you're basically getting rid of concurrent writers to your database. **[00:07:14]** But with that you get a shit ton of guarantees that make durable agents actually workable while stuff is running in parallel.

Eventually all of that stuff is committed, and once it's committed, anybody listening in on a harness or in a session can say, "Hey, what changed since the last time you gave me a state update?" and then visualize it. That's the basic principle: tasks write into **[00:07:39]** storage serialized and atomically, which gives me durable execution because I can persist the state perfectly, and anytime something changes in my store, all of my listeners or watchers that want to know what the latest assistant message or the latest chunk is get a notification: "Here's a little change in the state, visualize that."

### Opening a Harness: Registry, Storage, Models, and Pluggable Execution Environments (`00:08:01` – `00:10:52`)

**[00:08:01]** Basically, you open a harness—harness being your system prompt, your tools, a bunch of other stuff. **[00:08:25]** To give it that, you create a **registry** where all of that is installed. So I can plug in tools, and while the agent runs, I can plug them out again and put in new tools, because that's a thing that you want to do. For example, if you want to turn on safe mode or a sandbox mode, you give it a different set of tools or a different set of instructions or a different set of wrappers around tools that check parameters to `bash` and all that bullshit.

**[00:08:48]** So you do that here, and then you open the harness and give it a **storage**. It can be any kind of storage; the storage interface is super, super simple. We have implementations for SQLite; it can run on Postgres and Cloudflare Durable Objects; you have a JSONL backend so things get written to JSONL files on disk (you shouldn't do that, it's fucking stupid for a durable agent, [but] you can). **[00:09:13]** It also works with distributed databases. I've optimized it such that all of these sequential commits of state actually get batched up in a very simple, smart way [group commit], so you don't have a lot of round trips.

And then you also need to give it the **models** it can work with. It's basically just a registry saying this model is available for this URL using this AI SDK, OpenAI responses, whatever.

**[00:09:39]** And the real fun part is this [`env` / `ExecutionEnv`]: historically coding agents have a bunch of tools like `read`, `write`, `edit`, `bash`, and they are hardcoded to work on your local machine. That is very stupid, because agents nowadays want to access all kinds of machines. So instead what you do is you write your `read`/`write`/`edit`/`bash` tools in such a way that you give them an **execution environment** that is **[00:10:03]** basically a connection to any kind of machine anywhere in the world that only implements a very simple interface to interact with the filesystem (if available) and spawn processes or commands (if available). So all your tools stay the same irrespective of where they're working: it could be on my local machine, it could be on my phone in Termux (which is a Linux userland on Android), it could be on a Cloudflare computer **[00:10:28]** (which is a simulated computer). And this abstraction with an execution environment—which is also pluggable and you can rip it out and swap something in while the harness runs—makes that possible.

### Multiple Conversations & Forking (Slack Channel + Thread Example) (`00:10:52` – `00:11:55`)

**[00:10:52]** Then the final concept is: the harness has a **root conversation**, and a harness can have **multiple conversations**. Say I connect this harness to Slack, to a channel—that's my main conversation, right? Every time somebody pings my bot, that conversation gets a new input, a new submission; all the messages since it was last mentioned go into context, and it replies.

And then somebody spawns a sub-thread. Now you have a problem: your agent only has one transcript, right? How do we manage this if people keep writing to it in the main channel? **[00:11:16]** What happens if I write to it in the sub-thread? Well, I want to **fork the conversation** at the point of the thread, and have a second agent running on this forked conversation. But I don't want to instantiate a new harness and register all of this garbage again with it. It is still configurable per conversation—which model and which tools and so on and so forth—but the basic set of everything that's available, I configure once, give it to the harness, and the harness allows me to, in parallel, **[00:11:43]** run multiple conversations that can even be forked from each other at specific points in their conversation.

### Idempotency & Submissions (`00:11:55` – `00:14:25`)

**[00:11:55]** And the second thing that's really, really quite necessary if you do durable objects—it's a word I cannot pronounce, I have tried a lot of times over the past couple of months, I'll try it again: **idempotency**.

**[00:12:08]** Basically, you have a service that you tell: "Do a thing, change something in the world, and I also give you an ID for the job that you're doing." The next time I call you with this ID, either the job is already running and you say, "Yeah, it's running," or you start a job if it isn't running yet under this ID. That makes that service an idempotent service: **[00:12:33]** as long as I provide a key for a specific thing it does, it will not start it twice. Once-only run guarantee.

We do the same here with **submissions**. Say you have a shitty Slack integration: for some reason, it duplicates mentions and submits the mention multiple times even though it's the same thing. As long as I give this the same ID [`requestId`] when I submit it into a conversation, **[00:12:58]** you get back the same submission on which I can then wait. What's happening is: submission goes in as a prompt, the agent starts running, does its thing, and eventually gives you an answer. And the submission system tracks which submission gets which answer from which run, because you can have interleaved runs and so on. So all you do is you wait for that submission, **[00:13:22]** and you have idempotency.

So how does this look under the hood? We have a bunch of things in the harness: we have the configuration with the tools and the models and the system prompt stuff. And then all of that is handled with **tasks** that do a thing durably (durable execution, phases). **[00:13:48]** We record results as records or **entries**. For that we have the transcript as user messages, assistant messages, tool result messages—very easy. The **tasks** are also basically records that just store the current status of the task and any kind of task-specific checkpoint data that it needs for the next phase. And then we have **submissions**—**[00:14:10]** basically like an inbox where you put stuff in and you wait until it's answered and you can get the answer out.

### Documents: Versioned State & Deltas Instead of Raw Event Streams (`00:14:25` – `00:15:47`)

**[00:14:25]** And finally, we have **documents**. Who here knows MongoDB? Blast from the past. You probably all turned off of it because it's fucking garbage—it's actually pretty okay nowadays. What they did was they built a document database. **[00:14:36]** A document database has a bunch of very interesting properties: it's not SQL, which is very nice for some use cases. It turns out for storing state—either for an agent or for application data that belongs to the agent that you want to store along with all the agent stuff—a JSON document (something that follows the JSON standard / JSON object / JSON schema) **[00:14:58]** is actually a pretty nice storage format for a lot of things.

So we built a tiny little document database into the harness that works on this storage I showed before, which has a super simple interface you can implement. And **we are actually not emitting events** like you have in other coding agents or AI SDKs; **we are actually emitting a document**. **[00:15:22]** If you haven't seen it yet, you get a **snapshot** of the full document, and then you only get **deltas** on that document. The interesting part about that is it's basically events, just in a way more structured and more flexible way. I can **version** them. I can **migrate** them. And that's super important if you have long-running agents. All of this together has the same properties: everything is versioned, everything can be migrated, so you can have your 10-year-running agent.

### Walkthrough of a Run & Crash Recovery (`00:15:47` – `00:20:35`)

**[00:15:47]** Here's how it works:
1. The user puts an input in. I get a new submission with an idempotency key—`job-42`.
2. The harness says: okay, this was placed now, and I will start the task that kicks off the agent to do its thing. I can immediately store that user message as a transcript entry, because that user message is now part of the context. I store it away durably.
3. **[00:16:15]** The harness starts a task called `pi.generation`. All it does is: it collects the current context window, collects all the tools that are currently enabled, and tells the LLM provider, "Here's the context, please generate an answer." That task is `pending`, and then `running`.
4. When it runs, chunks stream in, and the document—`pi.live`, we call it—gets updated with new chunks. **[00:16:41]** If you watch that document in a UI, you just get the deltas naturally.
5. Eventually that is done, and the LLM didn't just give you text—it also made two tool calls. So what happens after this is we schedule two new tasks [`pi.tool`] in the task graph, one for each tool. They run independently, in parallel, or sequentially if you need that.
6. **[00:17:05]** We already persisted the assistant entry. When the tool tasks are done, we persist their results as well in the context, and that gets sent with the next LLM request. Then we have another `pi.generation` because the model didn't give us the final answer yet; it just said "I want these tools executed," then it gets tool results back, and then it gives me my final answer.

Now let's see what happens if this process crashes anywhere in the middle of this:
**[00:17:31]** The agent is currently running in Process A. We have already submitted the first input, and there is a queued input that waits until the next turn to be inserted into the context so you can steer the agent while it does things. We already have a bunch of tasks running based on the first input, and the generation task is waiting for the second tool call—the `bash` tool call—which is still running.

**[00:17:56]** And now we kill the process. All of this is persistent: in storage we know these are the submissions that are outstanding and waiting for an answer, these are the confirmed immutable context entries, and these are the tasks that are still pending/running in some way.

**[00:18:18]** Then I restart the harness in a new process. I basically just open the same harness on the same storage and say `resume()`. (You can also inspect what's about to be resumed if you want that, and can abort specifically things that you don't want to resume, though you generally don't have to.) I get the root conversation again, submit the same thing again with the same idempotency key, so I'm getting back the handle on which I can wait for my answer for `job-42`.

**[00:18:45]** And then, in this case, the harness decided that the `bash` tool that was interrupted **doesn't** get rerun again. Can somebody tell me why we don't want to rerun the `bash` tool execution? Because we don't know what it already did! **[00:19:05]** So instead, what happens is we tell the model: "Okay, this tool got interrupted because the process went away," and it gets that as a result in the transcript, and it generates its final answer.

Now, that alone is not very impressive—you could do that with event sourcing as well. The interesting part comes when you make the tools themselves **replay-safe**, because you can do that too. Say you give your agent a tool that lets it do a payment. **[00:19:31]** You don't want to repeat that, right? But you can make it so that it's replay-safe.
- Easy example: I have a search tool, `search_issues`. It takes a query from the model as the parameter. Can I replay that if it crashes mid-execution or not? Is that safe? Yes (`replay: "safe"`).
- **[00:19:53]** Then I have a `deploy` tool. If that crashes in the middle of execution and it gets called again, is that good or bad? Bad! Don't do this. So by default this is not replay-safe, and it will not get re-executed.
- **But** we could make `deploy` replay-safe by having an idempotency key and storing a **memo** on the task before calling the deploy service! **[00:20:18]** Since a tool can store memos and all kinds of other stuff, this tool can be made replay-safe.

### Custom Durable Tasks with Phases & Durable Timers (`00:20:35` – `00:21:45`)

**[00:20:35]** You can also define your own tasks in the harness. Say you give the agent a tool to remind itself to do something at a specific time in the future. **[00:20:42]** We can define this as a task that gets spawned by the tool we give the agent. That task has phases:
1. It starts with the `wait` phase, which sleeps for as many seconds as it needs based on the inputs.
2. Then it commits: "Okay, I'm done sleeping, my next phase is `deliver`."
3. **[00:21:04]** In the `deliver` phase, I pick up the conversation on which the tool was called that spawned the task, and I submit a new input with an idempotency key that reminds the model nine hours later: "Hey, do the thing!"

All of this is stored alongside the agent state in the harness, and it also becomes durably executable. That means if anything here crashes and we resume it, **[00:21:29]** that task is also resumed and can remind the model, and you don't have to do anything external in your system to make that work.

### Watching Views, Delta Encoding, and Multiplayer Fan-Out (`00:21:45` – `00:23:59`)

**[00:21:45]** There are things you can watch: you can watch tasks, you can watch documents (which store state). **[00:21:53]** For a conversation, we watch that conversation and we get a **view** that gives us delta operations (or a snapshot if it fully changed). In that state is: what is the current context (or the last 100 context entries), is something streaming at the moment, is a tool executing, if so what is its output, and so on and so forth. And it's very easy to render this.

**[00:22:19]** Pretty much all UI rendering toolkits you have—including web-stack-based ones or SwiftUI and all that stuff—**[00:22:46]** work like this: you give some widget some state, and if the state changes, it updates itself. What you get out of a watch from the harness is minimal state changes. If you use something like Solid, you can actually pinpoint what you want to update in your UI component.

**[00:23:11]** And the fun part here is also: if I have multiple UI clients watching the same conversation, they both get a view that is synchronized. Everybody sees the same thing, and I don't need to waste two channels computing separate streams—I can send both the exact same delta at any point in time. Magic of delta encoding. **[00:23:34]** It works beautifully. I had a session that I shared that was running on Pi Durable: the session ran on my phone, and 250 people joined via `ngrok`. They all watched me live-code, and it just works because everybody shares the same data and it just gets fanned out.

### Documents in Detail: Versioning, Scopes, History, and Fork Semantics (`00:23:59` – `00:26:40`)

**[00:23:59]** Finally, let me show you what a **document** is in the harness. As I said, everything is versioned. Say I want to add todos to my session / conversation:
- I define a document with a `kind` (a key for that kind of document, e.g., `"app.todos"`),
- I tell it `version: 1`,
- **[00:24:22]** I tell it the `scope` is for one `"conversation"` in my harness (or I can make it `"session"` global so it doesn't have a conversation key),
- I specify `history`: `"latest"` or `"rewindable"` (let me rewind the document to an earlier point in the transcript),
- **[00:24:48]** And I specify `fork`: what happens when a conversation to which this document is bound is forked? Do you want to have the state **at that fork point** (`"asOf"`), or do you want to have the **latest/current** state (`"current"`), or `"initial"`?
- And you specify the `initial` state of the document (in this case, an array of strings where each item is a todo item).

**[00:25:10]** How do we modify this? If you've worked with JSON patch / immutable draft libraries [like Immer / Mutative]: you say "I want to commit a change to this document," you get the document out for this conversation ID, and then you just modify the JavaScript object. That transaction records any changes to the object by the **[00:25:37]** magic of JavaScript `Proxy`s, and at the end that gets translated into delta operations that are super easy to store and very small to transmit.

And here's the fork thing: at the top is my main conversation (say, the Slack channel). Then at the second node I say: fork this conversation into a second conversation that shares the history **[00:26:02]** with the parent conversation up until that point. If that channel had a todo list document, that gets forked along—so I get a copy of the document for that new conversation forked off the parent conversation. And through the `history` and `fork` policy, I can say whether I want the document **as it was at that point** in the parent conversation (`asOf`) or **as it is currently** in the parent conversation (`current`). **[00:26:31]** With that, you can model any kind of state that you want to transfer across conversations, either anchored to a conversation entry or not.

### Summary of Pi Durable Guarantees (`00:26:40` – `00:28:06`)

**[00:26:40]** Benefits you get:
- **Exactly-once input** via submission idempotency keys.
- **Honest side effects:** If you call a service and you don't have an idempotency key / replay safety, we don't know if the effect happened or not, so we report it interrupted rather than blindly repeating it. **[00:26:56]** If you *do* have an idempotency key / replay-safe tool, we can replay your tools automatically.
- **Durable scheduling:** If a task crashes in any of its phases, it restarts and picks up where it left off.
- **Escape (Abort) that actually works:** In a lot of coding agents, if you press Escape, foreground child tasks/processes keep running in the background. **[00:27:20]** With the ownership task graph, we have automatic bottom-up distribution of abort signals.
- **Multiplayer consistent state** across clients.
- **Malleable while running:** **[00:27:41]** Pi is a thing that can modify itself while it runs, and the whole harness is built on this concept. Rip out tools, system prompt sections, switch in new stuff; rip out and migrate a task version and plug in the new version while the harness runs.
- **Runs anywhere** JavaScript runs and where you have some kind of storage.

### Demo 1: Pi Durable on Cloudflare Durable Objects (`00:28:06` – `00:30:40`)

**[00:28:06]** This first demo is something a teammate of mine, Christian, built. It runs on **Cloudflare Durable Objects**. In Cloudflare Durable Objects, you define a class in TypeScript that handles HTTP or WebSocket requests, and it also has state and an embedded SQLite database. **[00:28:33]** When anybody in the world connects to that object through HTTPS or WebSocket, that SQLite state gets loaded, and the Durable Object is live as a single-writer serialized instance. **[00:29:00]** Everybody can talk to it, and every mutation is serialized.

So Christian put Pi Durable in a Cloudflare Durable Object. The problem with Durable Objects is that they kill/evict themselves after running or idling: **[00:29:26]** they rip away the V8 isolate within which the Durable Object runs. With Pi Durable, that is not a problem: before the time runs out (or when sleeping), you set a Durable Object **alarm** to wake/restart the object. When the object gets killed and the alarm triggers, the object gets respawned, Pi Durable is told `resume()`, **[00:29:52]** and if your tools are replay-safe, it just picks up where it left off as if nothing happened, automatically.

### Demo 2: Live Phone-Hosted Multiplayer & Pluggable Execution Environments (`00:30:40` – `00:35:41`)

**[00:30:40]** And this second demo is my new Pi thing [p2 / Pi Mobile]. Let me show you what **execution environments** do. I can go up here and select from a list of devices I have: there's my laptop, **[00:31:05]** one Hetzner server, the other Hetzner server, and a `sandbox`—which is a QEMU sandbox running on one of my Hetzner boxes. So I'm going to limit this session to that sandbox, select a folder, and move into the sandbox.

**[00:31:30]** Now all of you people in the room can join me via QR code on a read/write link... **[00:33:58]** All of your messages are in steering mode, or we can switch into chat mode where you write `@pi` to talk to the agent. **[00:34:23]** There are now 25—now 51, 53—people in there. You're all getting this from my phone! All of these sessions are running on my Android phone. The only thing that's not running on my phone is the QEMU sandbox (which the tools execute against on Hetzner) and the LLM. Everything else—the web UI serving, the agent harness (Pi Durable), the SQLite store—is running on my phone. **[00:34:49]** Somebody figured out you can build artifacts. If my phone crashes, I can resume it and it can all retry. You can find it at `github.com/earendil-works/pi` under `packages/durable`.

### Q&A (`00:35:41` – `00:39:16`)

#### Q1: Multi-month / multi-year sessions and the LLM context window (`00:36:05` – `00:37:15`)
- **Question:** If this now runs for multiple months or years, what about the context window?
- **Mario Zechner:** LLMs have a limited context window, so I only need to select what fits into the context window. That selection is basically since the start of the chat or **since the last compaction**. For a long-running session, you can compact, **but the better way is actually to give your agent a tool to search its history** (`search_history` / `history`). Even if there's a compaction somewhere in a seven-year-old thread, the raw entries are still in storage, so the agent can search by range, dates, or keywords, and use the tool to pull back history (or augment it with memory / RAG).

#### Q2: Recovering from a poisoned / derailed conversation (`00:37:15` – `00:37:50`)
- **Question:** Let's say there is a part of the conversation that went off the rails and I don't want it in history—is there a way to remove that poison?
- **Mario Zechner:** Yes—you just go back to the entry before it went off the rails and **fork** from there. You now have a separate branch that shares the clean prefix and leaves the poisoned suffix behind.

#### Q3: Sycophancy and multiplayer coding in practice (`00:37:50` – `00:39:16`)
- **Question:** Have you found anything interesting about how sycophancy works in multiplayer (when two users disagree)? And have you seen engineering teams doing multiplayer coding in production?
- **Mario Zechner:** Sycophancy in multiplayer is specifically not solved! And as for multiplayer coding: it turns out that the solitary experience you have when coding also extends to coding with agents. I personally haven't had a single session where I collaboratively code in the same session with my coworkers. **Where it does help** is when you connect a session to a Discord or Slack channel: then we're not pair-coding with the agent, we're pinging the agent in a shared channel to react to what we typed—file an issue, check if there's something about this in the inbox, triage things, and so on.

---

## Part 2: Raw `sayneat` ASR Segment Log (`whisper`)

Verbatim segment output from `sayneat --transcribe --language en --transcript-format markdown`:

**[00:00:00] Speaker:** So yeah, I am on two hours of sleep, as you have noticed. I can't get basic things right anymore. So first question, who still reads the code? You liars, you filthy, filthy liars. Nobody's reading the code anymore, so I thought today instead of bringing shitty robots and...

**[00:00:25] Speaker:** doing other fun stuff. I'm going to do super fucking boring stuff and show you code. Remember the times when you looked at code? Good times. Remember the times when you wrote the code yourself? Pretty good times too. So I didn't write this, obviously. Didn't write a single line of this except for a bunch of interfaces and types to kind of steer the edge in the direction I want. And then I reviewed it. Out came something called pi-durable.

**[00:00:50] Speaker:** - No, who knows what Pi is? Okay, so lying probably, so coding agent, but a coding agent like Pi or Codex or Cloud Code or whatever you have, has a problem. And the problem is it's not terribly executing its stuff.

**[00:01:15] Speaker:** It's not doing the executing stuff. We're going to learn what it means in a bit. And it might even not do the store the stuff that happened. If you run Cloud Code or Pi, the tool is being executed, and you press Control C twice, then that tool call basically never happened. It's not in the storage of this codex. Same is true for many coding agents. Because in our day-to-day use of coding agents, we don't really care.

**[00:01:42] Speaker:** if the process that runs the agent falls over and kills itself and is restarted select the session and say continue right that works for us that doesn't work if you deploy an agent to a cloudflare durable object doesn't work if all of your agents are running on a pesky little phone with a memory limit and a process limit and i'm going to show you what runs on this later

**[00:02:08] Speaker:** It doesn't work if you deploy it to a robot with a battery that falls over when the battery is out. So basically what you want is your agents to restart in case of failure. You need a sort of supervisor that can start the process back up. That can be a double object on Cloudflare or some other serverless stuff. It can be just a supervisor process on the machine that spawns the agent again, whatever. And then the harness running the agent, harness being system prompt tools.

**[00:02:33] Speaker:** garbage and connection to the LLM. The harness should be able to resume from where it left off and it shouldn't have forgotten what it did. No output gets lost and try your best to reconstruct what's happening. That is why I built Pi Durable because it turns out our agents moving away from our devices. I mean, the LLM already lives in the cloud but also the agent loop itself.

**[00:02:59] Speaker:** harness they probably move into the cloud as well for reasons ram altman that's kind of a point i guess we can have my ramo met that body uh but he probably has a point that most of our agentic computing is moving to the cloud so that means you meet something that is horrible that is resistant to restarts

**[00:03:24] Speaker:** okay so hi durable in four sentences i totally wrote this myself twinkle blonky so it's not a coding agent it's a library for building agents right and it's written in type script because i hate myself i'm actually a c person but it turns out agents are very good with type script javascript is available pretty much anywhere including my esp32 devices now

**[00:03:48] Speaker:** You can do a lot of shit with JavaScript. Doesn't preclude it being ported to Rust, right? Because we know that's just a prompt away. That is fast. Or we can even do it in a set. What it provides you with is durable execution and storage. That means if the process kills itself, it can pick up where it left off. And everything that happened until that point was actually durably stored in some form of storage. Very nice.

**[00:04:16] Speaker:** And you also have scheduling. That is, everything within the harness session in PyDoreal is expressed as a task with phases, and each phase is basically record what you're about to do, do the thing, call it an effect, and when that returns with a result, persist the result and go to the next phase. We're going to look at what that means in code terms, so scary, I know, in a bit.

**[00:04:41] Speaker:** All of this is also inherently single and multiplayer, which is also something that's probably becoming more important as people realize that sitting in front of a computer talking to an agent all day alone fucking sucks and makes you mad and psychotic. So ideally, an agent joins us in our quest to write the most perfect software Opus can write.

**[00:05:05] Speaker:** um recovery and tracking state once we've killed the process so this is what we talked about earlier some stupid coding agent does a thing the process falls over because of a thing and then you reopen the session you type continue like a plaid um first you have a slack agent a bot in in slack like you have your open claw or your hermes or whatever and your instance in which you installed that garbage

**[00:05:29] Speaker:** falls over for some reason because it killed itself. It happens. And then you're like, what the fuck happened? Why doesn't it restart? And if it even restart, can it pick up from the very left? Probably not. It also extends to Cloudflare, serverless environments, and so on and so forth, or my phone, as I said earlier. The basic principle here is you have user inputs, you have model streams, you have tools that print stuff out, whatever happens.

**[00:05:56] Speaker:** gets persisted in a sequentialized commit log. Basically, it's not an event log. It's not event sourcing because that doesn't work for very long-running agents. So what you could do, what most harnesses do nowadays is anytime something happens, like I got the first token from the agent, I write it to disk as an event. If I get a thinking token, I write it to disk as an event. If I got the tool call, I write it to disk as an event. If my tool executes and spits out something, I write it to disk as an event.

**[00:06:23] Speaker:** Now you can do this for a coding session that's maybe 3,000 entries in the context, user messages, assistant messages, tool call and execution. You cannot do this for a Slack bot that is supposed to live for five years in a handful of channels with thousands of people. So event sourcing is a stupid fucking model for storing long running agent sessions and that's why we're not doing that.

**[00:06:47] Speaker:** Instead, we have state persistence through these tasks, through this effects and which I talked about earlier. And to have those durability guarantees, we need to serialize every state change in all of these tasks in sequential order. That sounds scary if you still know what that means. In database terms, you're basically getting rid of multiple rights to your database.

**[00:07:14] Speaker:** But with that you get a shit ton of guarantees that make durable agents actually workable while stuff is running in parallel. Lots of words, nobody knows what I'm talking about. Eventually all of that stuff is committed and once it's committed, anybody listening in on a harness or in a session can say, "Hey, what changed since the last time? You gave me a state update and then I can visualize it." That's the basic principle. Some tasks right into a...

**[00:07:39] Speaker:** in a storage serialized atomically gives me durable execution because i can persist the state perfectly and anytime something changes in my store all of my listeners or watchers that want to know what the latest assistant message is or the latest junkies get a notification and say here's a little change in the state visualize that what that looks like

**[00:08:01] Speaker:** I see shocked faces. Yes, this is what it used to look like when you worked on code. Young people probably have never seen something like this. Great, I can't fucking... Nothing changes if I zoom in, so I hope you have very good eyes like me. Basically, you open a harness, right? Harness being your system prompt, your tools, a bunch of other stuff.

**[00:08:25] Speaker:** And to give it that, you create a registry where all of that is installed. So I can plug in tools. And while the agent runs, I can plug them out again and put in new tools, because that's a thing that you want to do. For example, if you want to turn on safe mode or whatever, a sandbox mode, you give it a different set of tools or a different set of instructions or a different set of wrappers around tools that check parameters to bash and all that bullshit.

**[00:08:48] Speaker:** So you do that here, and then you open the harness, and you give it a storage. And it can be any kind of storage. The storage interface is super, super simple. So we have implementations for SQLite. It can run on Postgres and Cloudflare a durable object. You have a JSON-L backend, so things get actually written to JSON-L files on disk. You shouldn't do that. It's fucking stupid for a durable agent. You can. So the world is the oyster, and you can do whatever the fuck you want here.

**[00:09:13] Speaker:** It also works with distributed databases. I've optimized it such that all of these sequential commits of state actually get batched up in a very simple, smart way. So you don't have a lot of round trips. And then you also need to give it the models it can work with. It's basically just a registry saying, this model is available for this URL using this AI SDK, from AI responses, whatever.

**[00:09:39] Speaker:** And the real fun part is this . Historically coding agents have a bunch of tools like read/write/edit/bash and they are hard coded to work on your local machine. That is very stupid because agents nowadays want to access all kinds of machines. So instead what you do is you write your read/write/edit/bash tools in such a way that you give it an execution environment that is

**[00:10:03] Speaker:** Basically a connection to any kind of machine anywhere in the world that only implements a very simple interface to interact with the file system if it's available and spawn processes or commands if available. So all your tools stay the same irrespective of where they're working. It could be on my local machine, it could be on my phone in Termax, which is a Linux user land on Android. This could be on Cloudflare computer.

**[00:10:28] Speaker:** which is a simulated computer. And this abstraction with an execution environment, which is also pluggable and you can rip it out and swap something in while the harness runs, makes that possible. We'll see how that works later. Small shitty demo. Then the final concept is the harness is a root conversation. A harness can have multiple conversations. So say I connect this harness to Slack.

**[00:10:52] Speaker:** to a channel that's my main conversation right every time somebody pinks my bot that conversation gets a new input new submission all the messages until it's last mentioned those go into context and the replies and then somebody spawns a sub thread now you have a problem your agent only has like one transcript right how do we manage this if people keep writing to it in the main channel

**[00:11:16] Speaker:** What happens if I write to it in the sub-channel? Well, I want to fork the conversation at the point of the thread. And I have a second agent running on this forked conversation. But I don't want to instantiate a new harness and register all of this garbage again with it. This is still configurable per conversation, which model and which tools and so on and so forth. But the basic set of everything that's available, I configure one, give it to the harness, and the harness allows me to, in parallel--

**[00:11:43] Speaker:** run multiple conversations that can even be forked from each other at specific points in their conversation. Does it make sense? Somebody needs to not. So I feel like I'm-- Yeah. Perfect. Good. There will be a test later. And the second thing that's really, really quite necessary if you do durable objects, it's a word I cannot pronounce. I have tried a lot of times over the past couple of months. I'll try it again. Item potency.

**[00:12:08] Speaker:** So basically you have a service that you tell do a thing, change something in the world. And I also give you an ID for the job that you're doing, right? The next time I call you with this ID, either the job is already running and you say, yeah, it's running, or you start a job if it isn't running yet under this ID, right? So that makes that service an idempotent service.

**[00:12:33] Speaker:** As long as I provided a key for a specific thing it does, it will not start it twice. So one's only run guarantee. And we do the same here with submissions. So then you have a shitty Slack integration. For some reason, it duplicates mentions and submits the mention multiple times, even though it's the same thing. As long as I give this the same ID when I submit it into a conversation,

**[00:12:58] Speaker:** you get back the same submission on which I can then wait. So what's happening is, submission goes in as a prompt, the agent starts running, does its thing, and eventually gives you an answer. And the submission system tracks which submission gets which answer from which run, because you can have interleaved runs and so on. So all you do is you wait for that submission.

**[00:13:22] Speaker:** And you have an item potency. I'm so proud of myself. You can't even imagine. Super simple and it's code. Just basically what I already said. So how does this look under the hood? We said we have a bunch of things in the harness. We have the configuration with the tools and the models and the system prompt stuff. And then all of that is handled with tasks that do a thing, durably, durable execution, phases, whatever.

**[00:13:48] Speaker:** We record results as records or entries. For that we have the transcript as user messages, assistant messages, tool result messages, very easy. The tasks are also basically records that just store the current status of the task and any kind of data that's task specific that it needs for the next phase. And then we have submissions.

**[00:14:10] Speaker:** It's basically like an inbox where you put stuff in and you wait until it's answered and you can get the answer out. And finally, we have something that's not very well described here, but we're going to look at it in a later slide, documents. So who here knows MongoDB? Last from the past. You probably all turned off of it because it's fucking garbage. It's actually pretty OK. Nowadays, it didn't use it. But what they did was they built a document database.

**[00:14:36] Speaker:** document database has a bunch of very interesting properties that is it's not sql which is very nice for some use cases it turns out storing state either for an agent or for data that brings to the agent that you want to store along with all the agent stuff a json document so something that follows the json standard or json object or json schema

**[00:14:58] Speaker:** is actually a pretty nice storage format for a lot of things, right? So we decided we basically built a tiny little document database into the harness that works on this storage I showed before, which has a super simple interface you can implement. And we are actually not emitting events like you have in other coding agents or AI SDKs. We are actually emitting a document.

**[00:15:22] Speaker:** If you haven't seen it yet, you get a snapshot of the full document. Then you only get deltas on that document. And the interesting part about that is it's basically events, just way more structured way and more flexible. I can version them. I can migrate them. And that's super important if you have long running agents. So all of this together has the same properties. Everything is versioned. Everything can be migrated. So you can have your 10 year running agent.

**[00:15:47] Speaker:** And here's how it works. The user puts this in. I get a new submission with an item potency key-- just going to say that word for the rest of time-- job 42. The harness says, OK, this was placed now, and I will start the task that kicks off the agent to do its thing. So that I can immediately store as a transcript entry, because that user message is now part of the context. I store it away, durably.

**[00:16:15] Speaker:** And the harness started a task called PyGeneration, and all it does is it collects the current context window, it collects all the tools that are currently enabled, and then tells the LLM provider, here's a context, please generate an answer. That is pending, and it's running. When it runs, chunks stream in, and the document, PyLive, we call it, gets updated with new chunks.

**[00:16:41] Speaker:** If you watch that document in a UI, you just get the deltas, naturally. And eventually that is done. And the LLM didn't just give you text, it also made two tool calls. So what happens after this is we schedule two new tasks in the task graph, one for each tool. They run independently, in parallel, or sequentially, if you need that. And then they start running.

**[00:17:05] Speaker:** And we already persisted the assistant thing. When they're done, we can persist their results as well in the context, right? And that gets sent with the next LLM request. And then we have another generation because the model didn't give us the final answer yet. It just said, OK, I want these tools executed. Then it gets tools results back. And then it gives me my final answer, which is this, right? And now let's see what happens if this process crashes anywhere in the middle of this.

**[00:17:31] Speaker:** So the agent is currently running in process A. We have already submitted the first input and there is a cute input that waits until the next turn to be inserted into the context so you can steer the agent while it does things. We already have a bunch of tasks that are running based on the first input and the generation task is waiting for the second tool called the bash tool call which is still running.

**[00:17:56] Speaker:** And now we kill the process. All of this is now persistent. So in the storage we know these are the submissions that are outstanding and waiting for an answer. These are the confirmed immutable context entries. And these are the tasks that are still pending in some way.

**[00:18:18] Speaker:** Then I restart the harness in a new process. I basically just open the same harness on the same storage and say resume. You can also inspect what's about to be resumed if you want that and can abort specifically things that you don't want to resume. You generally don't have to do that. I get the root colonization again. It's a bit the same thing again with the same idempotency key. So I'm getting back the handle on which I can wait for my answer for the input, chop 42 or whatever.

**[00:18:45] Speaker:** And then, in this case, the harness decided that the bash tool that was interrupted doesn't get rerun again. Can somebody tell me why we don't want to rerun the bash tool execution? OK, you're laughing. Good. You're actually paying attention. Yes, I didn't build it. Oh my god.

**[00:19:05] Speaker:** So instead, what happens, we tell the model, OK, this tool got interrupted because the process went away or whatever, and it gets that as a result in the transcript, and it generates its final answer. And that's one way of doing it. Now, that's not very impressive, right? You could do this with an event source as well. The interesting part comes when you make the tools themselves replay safe, because you can do that too. And say you give your agent a tool that lets it do a payment.

**[00:19:31] Speaker:** You don't want to repeat that, right? But you can make it so that it's replay safe. I give you easy examples to understand that concept. I have a search tool, search issues. It takes a query from the model as the parameter. Can I replay that if it crashes mid execution or not? Is that safe? Yes, good. You get a star and an A.

**[00:19:53] Speaker:** then i have a deploy tool if that crash is in the middle of execution and it gets called again is that good or bad scream it out like it cashball don't do this right so this is not replay safe so it will not get re-executed but we could make this replay safe we can make it replay safe by deploying having and yes

**[00:20:18] Speaker:** Perfect. So if we do this, and the tool can do memos and all kinds of other stuff, this tool can be made replacing. Isn't that nice? It's very nice, right? You can also define your own tasks in the harness. Say you give the agent a tool to remind itself to do something at a specific time in the future.

**[00:20:42] Speaker:** We can define this as a task that then gets spawned by the tool we give the agent. That task has phases. It starts with the wait phase. Wait phase basically just sleeps for as many whatever seconds it needs based on the inputs. Then it commits, OK, I'm done sleeping. My next phase is delivered. So I go to the next phase.

**[00:21:04] Speaker:** Next phase, I pick up the conversation on which the tool was called that spawned the task, and then I submit a new input with an item potency key that reminds the model nine hours later, "Hey, do the thing!" And all of this is stored alongside the agent state in the harness, and it also becomes durably executable. But it means if anything here crashes, and we assume it...

**[00:21:29] Speaker:** that task is also being resumed and can remind the model and you don't have to do anything in your system to make that work yeah so blah blah blah blah blah that's the least fun part so basically you already said about there's things you can watch you can watch tasks you can watch documents which basically store state the way you do it you set up your thing and then you say

**[00:21:53] Speaker:** for this conversation, in this case it's called the thread, we watch that thread and we get a view that gives me delta operations or a snapshot if it fully changed that state. And in that state there is what is the current context or the last 100 context entries, is something streaming at the moment, is a tool executing, if so, what is its output and so on and so forth. And it's very easy to render this.

**[00:22:19] Speaker:** How am I doing on time? We're good. Just take us. How much time do I have? Seven minutes. We're going home early today. Just go ahead. Easy peasy, lemon squeezy, basically all the UI rendering toolkits you have, including WebStack based ones or Swift UI and all that stuff.

**[00:22:46] Speaker:** basically works like this. You give some which at some state, and if the state changes, it updates itself. And what you get out of a watch from the harness is exactly that kind of state, minimal. So if you use something like solid, you can actually pinpoint what you want to update in your UI component. Do something like React. That's your problem. It was an ad not paid by solid.

**[00:23:11] Speaker:** And the fun part here is also, if I have multiple UI clients watching the same conversation, for example, they both get a view that is synchronized. So everybody sees the same thing. And I don't need to waste two channels. I can send both the exact same thing at any point in time. Magic. Magic of Delta encoding.

**[00:23:34] Speaker:** I'm not going to explain it, but it works beautifully. And I had a session that I shared that was running on Ply Durable. Session ran on my phone and 250 people joined via ngrok. They all watched me live code. It's a stupid thing I'm going to show you next. And it just works because everybody shares the same data. It just gets funneled out.

**[00:23:59] Speaker:** helps with multiplayer and then finally let me just show you what the document is in the harness so as i said everything is versioned i think yeah so i define let's say i want to add to do's to my session to my conversation so they find a document i say it's kind this is basically a key for that kind of document i tell it this is version one

**[00:24:22] Speaker:** I tell it the scope of this is for one conversation in my session, in my harness. I can also make it harness or session global so it doesn't have a conversation key to it. And then I can say something which I can explain with a graphic later, a history. There's a couple of versions. Give me the latest one. Let me rewind the document. That makes sense in a bit. And there's a third one, which I forgot. And you can also say

**[00:24:48] Speaker:** what happens in case a conversation is forked to which this document is bound? Do you want to have the state at that fork point? Or do you want to have the latest state? You can do all kinds of post-it with this kind of thing. And you also say what's the initial state of the document. And this is, in this case, it's just an array of strings. Each item is a to-do item, right?

**[00:25:10] Speaker:** So then how do we modify this? Well, this might sound familiar, look familiar if you work with these kinds of JSON, what's it called, JSON patch libraries, like, I forgot its name, something with name, Taylor, now that's not. You basically just say, I want to commit a change to this document, you get the document out for this conversation ID, and then you just modify the object, JavaScript object, and that transaction records any changes to the object by the

**[00:25:37] Speaker:** magic of javascript proxies and at the end that gets translated into delta operations that are super easy to store and very small to transmit and here's the fork thing so i have at the top there's a line that's my main conversation right say the slack agenda then at the second little noodle i say fork this conversation into a second conversation that shares the history

**[00:26:02] Speaker:** with this other conversation up until that point. And if that channel had a to-do list, that gets forked along. So I get a copy of the document for that new conversation forked off the other conversation as well. And I can then, through the power of this history and fork things, say, do I want the document as it was at that point in the other conversation? Or do I want the document as it is currently in the other conversation?

**[00:26:31] Speaker:** and a bunch of other common features. And with that, you can basically model any kind of state that you want to transfer between sessions, either anchored to a conversation entry or not. Benefits for free. I also totally didn't write this. That's why it's precious as exactly one's input. The side effects are honest. If you call a service and you don't have an idempotency key, we don't know if the effect happened or not. So you better give up.

**[00:26:56] Speaker:** If you do have an item potency key, you can replay your tools, which is super fucking nice. We have this durable scheduling thing. If a task crashes in any of its phases, it's just restarted and picks up where it left off. Escape that actually works. Like in a lot of coding agents, if you press escape, you have tasks that are still running, which are foreground tasks, which don't fucking stop. And then you wonder, hey, Claude.

**[00:27:20] Speaker:** Why are there 10 more processes running than I thought would run after this command? I don't know. You press escape. And with this task graph, we have automatic distribution of any kind of a port signal, which is also . Many clients already talked about that consistent state. It's also very nice across clients. And you can change it while it runs.

**[00:27:41] Speaker:** because Pi is a thing that can modify itself while it runs. So the whole harness is built on this concept. Rip out tools, system prompt stuff, blah, blah, blah, switching new stuff. Rip out, migrate a task version and plug in the new version while the harness runs. Works as well, migration, automatic, blah, blah, blah. And it runs basically anywhere JavaScript runs and where you have some kind of storage. So OK, let me just show you two things.

**[00:28:06] Speaker:** This is a demo a friend of a teammate of mine, Christian, built. It runs on Cloudflare durable objects. Who doesn't know what that is? Is there anyone that knows what that is? OK. Basically, you define an object in TypeScript that says, if I get a request here, do a thing, like basic web server stuff. But it also has state. It's like an object with state, like fields, and a SQL database, SQLite database.

**[00:28:33] Speaker:** And so when anybody in the world connects with that object through either HTTPS or WebSocket, that state gets loaded, the SQLite database gets loaded, and from there on, the durable object is live everywhere in the world. And any modifications to that state through HTTP or WebSocket get synchronized between the actual instances that must be running in the background, because you can't have just one object that everybody writes to.

**[00:29:00] Speaker:** But Cloudflare magically synchronizes all of that. So for you, it looks like you have a single object with a single address. And everybody can talk to us, and every mutation is serialized. Sounds familiar, right? Serialization. Interesting. So what Christian did here is he put PyDurable in a Cloudflare durable object. The problem with durable objects is that they kill themselves after 15 minutes of running. So if you have a coding agent that runs in a durable object after 15 minutes--

**[00:29:26] Speaker:** it's just gone. They rip away the V8 process, the V8 isolate within which the durable object runs. So with PyDurable, that is not a problem because before the 15 minutes run out, I can set an alarm to restart the object so it gets another 15 minutes and then the object just gets killed and the alarm triggers, my object gets respawned, PyDurable is told resume little buddy.

**[00:29:52] Speaker:** And if all your tools are replay safe, it just picks up where it left off as if nothing happened. And it's automatic. And this is how you want a system like this to work. And well, this is super interesting because I can say hi here. It probably doesn't work because it does. Let's see the sys. Yeah, whatever. Hi, Boo Boo. What can I help you with? And I have a second thing here.

**[00:30:17] Speaker:** and of course it's broken okay to be fair christian just uh let's see joining us oh sorry i need to join from another you can imagine what it looks like right

**[00:30:40] Speaker:** And this is my new Pi thing. It's just a Pi, just web interface, and it's also mailable. You can put new stuff into it. And now let me create a QR code. Let me show you what execution environments do. Basically, I can go up here and select from a list of devices I have. There's my laptop, my...

**[00:31:05] Speaker:** one headsner the other headsner and i have a sandbox which is basically a qemo sandbox running on one of my heads so i'm going to limit this machine to that sandbox but the sandbox actually live so this is my sandbox now i can select a folder where the agent has its current recognition and then i say yeah sure let's move into the sandbox so now all of you people

**[00:31:30] Speaker:** and actually join me. So should we make it a read/write link so you can also talk or should it mention a read only thing? Let's make it a read/write link. QR code generator. And now my phone is probably going to burn the phone.

**[00:31:56] Speaker:** Doesn't work? Oh, sorry. Doesn't work, then demo gods hate me and I'm gonna go curl up in a corner. Nobody says it works and I also see nobody connecting, so something's wrong. Does anybody get an error message? You're all engineers, can you just give me a good bug report, please?

**[00:32:23] Speaker:** okay can somebody chat yeah yes who pays the bills so what do you want see what any enough are you on it oh no where the are you people i see the message that's a streaming that's surprising also this is how you share with our code uh the phone

**[00:32:46] Speaker:** I gave you the wrong thing. I gave you the example from before. I see all right. Quite some tokens. Does this work? I think it's the same thing. Oh, I didn't do the thing. I'm so stupid.

**[00:33:09] Speaker:** I see messages like as many tokens as possible. I really hope I get you the link to the right session. Sorry. Everybody done? Yes. Yeah? We good? Can you get in? Seven people are in.

**[00:33:34] Speaker:** What happened to everybody else? It could be that since I'm using my mobile apps and I'm streaming my screen. Seems like someone managed to come through. Benny says send API keys.

**[00:33:58] Speaker:** Family name in there, so he's not anonymous anymore. All of your messages are in steering mode. So yeah. But here's what we can also do. Let's go into chat mode. So we can chat. And if you want to talk to the little thing, just write @py. OK? So you probably can. Very terrible transcript.

**[00:34:23] Speaker:** Let me just check how many people are in there. There's now 25 people in there. You're all getting this from my phone. All of these sessions are running on my phone. The only thing that's not running on my phone is the sandbox, which you now have access to. You can instruct the client to tell you what's in the sandbox. MTLLM, obviously not running on my phone. Everything else is running on my phone. The web UI and the serving of that, the agent horn is pirurable, and so on and so forth.

**[00:34:49] Speaker:** It's serving 51 people now. This Pi actually, it sinks. I'm not aware of any profanity filter in this chat. This is a shriek meter. So now you know my open claw is kind of a bad idea because this happens when you do old saws. Okay, there's now 53 people. Okay, my point still stands. This is all running on Pi Durable on my phone. If my phone pressures...

**[00:35:16] Speaker:** That's me. Somebody figured out you can build artifacts. I hope you don't figure out all the other stuff you can do. Yeah, again, point being, this runs on my phone. Stupid Android phone. If it crashes, I can resume it, and it can all retry. So if you have agent workloads, consider Pi durable. It's really cool. Thank you for reading the code.

**[00:35:41] Speaker:** Let's take some questions from this room and I am hoping to figure out how to get your questions from now. - Yeah, you can find it at GitHub.com/erendill/works/pi. Everything pi is in there.

**[00:36:05] Speaker:** totally dead and it's under one of the packages. Just put your agent. Yes? If this now runs for multiple months, years, what about the context window? So the fun part is that LLMs have a limited context window, right? Yeah. So I only need to select what fits into the context window, right? That selection is basically since the start of the chat or since the last compaction. Because if you have a long-running session...

**[00:36:31] Speaker:** That's the only thing you can do, you can compact. But the better way is actually to give your agent a tool to search its history. Let me demonstrate. Use the history tool to tell me what the first message was. Now assume that there's a compaction somewhere in here because this is a seven-year-old thread. You can just search by range, dates, blah blah blah, keywords.

**[00:36:56] Speaker:** I'm an idiot. And it just uses the tool to get back to history. Obviously, you can augment it with memory, with REC. If it is new join is new session. Let's say there is a part of the conversation that I don't want to be in history. Is there a way to poison that? Like remove it?

**[00:37:19] Speaker:** I was saying it went off the rails into some direction that I didn't want it to reset it. Yeah, sure. You can just basically, I don't know, if you don't like, I can say back here. That is that fork thing. So I'm now basically...

**[00:37:43] Speaker:** worked off of that part of the conversation. I now have a separate branch. They can basically get rid of the poison if I want to. Have you found any fun stuff about how Psycho Fantasy works in multiplayer? Like if I'm right and you're absolutely right, like who's absolutely right? Nobody's ever absolutely right. Specifically not solved. Like if it's a multiplayer, if...

**[00:38:05] Speaker:** not agrees with me and then agrees with you. Is it just like recency bias or is it? I don't know, try it out. You can run this in a day. My friends have fun. Don't burn the internet down. Have you seen many engineering teams in production already doing multiplayer coding? Not us. So it turns out that the solitude, the solitary experience you have when coding.

**[00:38:30] Speaker:** also extends to coding with agents. I personally haven't had a single session that I share through this system with my coworkers. Where it does help is if you take that I can connect this session to one of our Discord channels, for example, and it becomes useful. Because then I'm not coding with the agent, then we are just pinging the agent to see what we typed and react on that. File an issue, tell me if there's something about this in the inbox, stuff like that.

**[00:38:58] Speaker:** there it's a bit useful for coding i didn't find it useful okay i think i wasted enough of your time if anybody has more questions i'm probably here for another or so just to go to the toilet and we can do this outside that later yes thank you very much
