# The Simplest Demo of pi-durable

- **Video URL:** https://www.youtube.com/watch?v=SBEGweMW3BM
- **Channel:** Official Channel for Exe Dev
- **Published:** 2026-11-18
- **Duration:** 00:05:51 (351 seconds)
- **Demo / deployment guide linked in the video:** https://exe.dev/deploy/pi-durable
- **Audio SHA-256 (`audio.webm`, format `251-19`):** `5c3b3eef07eb048b1223ffd820e840d2a4565cca713f4f034f8bc5ead81f59d5`
- **Transcription tool:** `sayneat --transcribe --language en --transcript-format json` (local Whisper Turbo, 15 speech windows)

Machine-generated audio transcript, cross-checked against YouTube's English automatic captions. Punctuation and technical spellings normalized for readability: Pi / pi-durable, SQLite, Datasette, systemd, jq, exe.dev, Zed, and Pi AI. Timestamps mark the starts of ASR windows, not individual sentences. This is a transcript of the speaker's claims, not an independent verification of recovery guarantees or product details; minor recognition errors may remain.

## Video chapters

- [00:00 — Intro](https://www.youtube.com/watch?v=SBEGweMW3BM&t=0s)
- [00:11 — pi breaks](https://www.youtube.com/watch?v=SBEGweMW3BM&t=11s)
- [01:11 — pi-durable does not](https://www.youtube.com/watch?v=SBEGweMW3BM&t=71s)
- [01:50 — Peek inside SQLite](https://www.youtube.com/watch?v=SBEGweMW3BM&t=110s)
- [03:08 — Peek at the code](https://www.youtube.com/watch?v=SBEGweMW3BM&t=188s)
- [04:45 — Try this yourself](https://www.youtube.com/watch?v=SBEGweMW3BM&t=285s)

## Transcript

**[00:00:00]** There's a new tool called pi-durable, and as the name implies, it's made by the same people who made Pi. And the easiest way to explain what it does is to show you how the original Pi can fail just a little.

What you see here is running on a VM, and I'm starting up Pi with a command: "Count to 30 with Bash, one number a second, and then tell me how far you got." And you can see that when I start running this, here's the Bash command. There's a little sleep, and you can see it starting to count.

**[00:00:25]** What I can now do is I can pretend that maybe something epically fails. So I'm going to hit Ctrl-C, shut this thing down. And then while that tool was being called, while this was running, a failure has happened.

Now, what I can do is I can resume this session. So I'm just going to copy that line, going to paste it back in. And I can see the command that indeed it was trying to run.

**[00:00:46]** But if I now were to ask, "How far did you get?" it's saying, "Look, I started the Bash loop to count to 30, but no output was returned, so I can't verify how far it got."

This is something that pi-durable can tackle. The whole idea is that pi-durable is just going to store more such that it can recover better. There's going to be a SQLite database, and if you use the pi-durable SDK, then things are going to get logged there immediately. So to demo that, on the same VM, I'm running this web app. I can say hi.

**[00:01:15]** And from here, what I can also do is give it the same task as before: count to 30 with Bash once a second. And this web app is going to show that indeed something is running.

What I'm going to do now is go back to my little terminal, and I'm going to say, "Look, let's kill that pi-durable thing that's running." If I now go back and if I were to restart this—which actually systemd does on my behalf, because this is running with that—then you can see that indeed at some point we did stop, and it is able to recover.

**[00:01:42]** The big difference here is that this tool call itself is being logged. And one way to maybe explore that is to actually have a peek inside of the SQLite database.

My favorite tool for exploring these SQLite databases is Datasette. So I just pointed Datasette to it, and you can see that we have a SQLite database with a couple of tables. And the thing that's going to be most interesting to us is this `entries` table over here.

**[00:02:03]** There's this one conversation ID, there's this commit, but mainly you can see this point in time here when I said hi. We also see a system prompt. That's what's happening over here. We can also see its first response. We can also see over here that I'm asking it to count to 30.

And then over here, we do see the actual tool call itself. There's an ID listed here, and we are also…

**[00:02:27]** …seeing the arguments. I think for the next step, actually, it might just be better to use jq for this. So what I'm able to do, because this VM is running on exe, I'm able to SSH, do a quick curl command from inside, and then I'm also able to run jq.

And one thing that's pretty neat is here you can see the one thing I was interested in. So you can see I was calling Bash. This is the JSON that was in the table. And you can also see, hey…

**[00:02:52]** …this bit of text over here, that is the actual Bash output. But this one log, that is something that we can give to the agent after it recovers. That is something that's now being stored. That's also something that you can use to boot back up. So that is where this 15 over here comes from.

A quick final thing that's also good to show. So this is my VM. I can click here and quickly open this up in an editor. Let's open it up in Zed locally.

**[00:03:17]** So this is all happening over SSH, but the important thing that I wanted to show you is happening over here in the bottom. You can see that we're setting up the models over here. So we're connecting to OpenAI, we're connecting to Anthropic. That's all well and good.

But we are also creating this one little registry. And in that registry, we are also installing coding tools. Now, those coding tools…

**[00:03:40]** …that's kind of the crucial thing. That comes out of that pi-durable library. Coding tools is something that Pi doesn't give us. It definitely comes out of pi-durable. And the whole idea is that when you use this, you are going to get the logging into SQLite added in.

So there's a difference. The models themselves, they actually come from the original Pi AI library. So pi-durable will have an interaction with the normal Pi…

**[00:04:05]** …codebase, but this is something that allows you to create the models. You can also get tools from elsewhere, but these tools are special. These are actually logged the right way to pi-durable as well. So that's the big difference.

The way you should think about pi-durable is it's not so much an agent. It's not like you can call it from the command line and you get the full harness that you can immediately talk to. It is more like an SDK. You get the building blocks, but the whole idea that you can build things that are recoverable, that is the whole point.

**[00:04:31]** And you can imagine in a lot of workflows where that's going to be not just useful, but also maybe necessary, especially if you're going to spin up lots of sub-agents. If any of those sub-agents fail—you can come up with lots of reasons why they might—then you want those to be able to recover, and this is a system that can do that.

Now, if you want to run this yourself, one fun fact: I'm running all of this on exe.dev. That comes with a lot of benefits. But one cool thing that you can do is you can start up a VM with a prompt, effectively. The whole pricing strategy is you pay…

**[00:04:57]** …for an instance of compute. That instance of compute can be split up into 50 separate VMs. And if you want to run this whole demo, what you can just do is give your VM a nice name, "demo for pi-durable."

And then this page, which I'll link to, contains everything that you might need to run this full demo yourself as well. When you do all of that, you end up on a page that looks like this.

**[00:05:18]** You can talk to a coding agent that's attached, you have a terminal, you can also quickly go to an editor. But a real big killer feature here is if I were to take this URL and if I were to open up a private browser, then you can see that I'm being redirected to log in again.

So if you want to have a VM for lots of personal projects, this is definitely a fun way to do it. And I can also imagine that using pi-durable, if you're doing things with agents, that is a good SDK to play around with.

**[00:05:41]** It's one of those AI tools where there's actually very little hype, but it definitely feels like there's a bunch of sane defaults in here. So yeah, I'm going to be diving into this more myself as well.
