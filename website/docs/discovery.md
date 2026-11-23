# How people might find H

**Decision for the preview: keep H.** Introduce it as **H, a local coding-agent daemon**. The useful thing to remember is what happens when a developer tries a second approach: they can branch at an earlier entry and keep reading either conversation. Put that example on the home page before the Elixir architecture. Make setup the next step after the demo. Neither the name nor a domain is a launch commitment.

## Names and addresses

| Name considered | What someone gets from hearing it | Cost of choosing it |
| --- | --- | --- |
| H, with the descriptor above | Matches the manual, `H.*` modules and `h-daemon` command. `hi` remains the name of the terminal client. | A single letter is a poor search query or referral on its own. Include the descriptor in page titles, link text and introductions. |
| Harness | A term used by people building agents. | Also the name of an existing [software delivery platform](https://www.harness.io/). A search for “Harness” need not have anything to do with local sessions. Use *harness* as a category, not a proposed trading name. |
| Forkledger | This proposed name points to two actual properties: branching and a record of what happened. | Could just as easily be a Git or accounting tool. The matching .com returned a domain object. A rename would leave readers translating between the site, H and `hi`. Not enough gain to justify that split. |

**Domain check, 21 November 2026, 12:08–12:09 UTC.** The [IANA DNS RDAP bootstrap](https://data.iana.org/rdap/dns.json) listed Google Registry for `.dev` and Verisign for `.com`. I made one anonymous HTTPS GET per name directly to the listed registry, with no redirects or retries. These are observations at check time; the links return *current* answers.

| Name and registry lookup | Response observed | Decision |
| --- | --- | --- |
| [hdaemon.dev](https://pubapi.registry.google/rdap/domain/hdaemon.dev) | 404, RDAP `errorCode: 404`, `hdaemon.dev not found` | First choice to investigate for H: easy to derive from the daemon name, though it needs spelling out aloud. |
| [hsession.dev](https://pubapi.registry.google/rdap/domain/hsession.dev) | 404, RDAP `errorCode: 404`, `hsession.dev not found` | Shortlist: names the object the user works with; less obviously a developer tool. |
| [forkledger.dev](https://pubapi.registry.google/rdap/domain/forkledger.dev) | 404, RDAP `errorCode: 404`, `forkledger.dev not found` | Shortlist only if the owner reopens the name decision. |
| [hdaemon.com](https://rdap.verisign.com/com/v1/domain/hdaemon.com) | 200, `domain`, `HDAEMON.COM` | Registered; not on shortlist. |
| [forkledger.com](https://rdap.verisign.com/com/v1/domain/forkledger.com) | 200, `domain`, `FORKLEDGER.COM` | Registered; spelling the suffix matters. |
| [harness.com](https://rdap.verisign.com/com/v1/domain/harness.com) | 200, `domain`, `HARNESS.COM` | Registered. This does not identify the operator of harness.io. |
| [hsessionlab.com](https://rdap.verisign.com/com/v1/domain/hsessionlab.com) | Incomplete transfer (curl 56); status line 404 but no complete RDAP body | Unknown; excluded. |

To repeat one check, leave `--fail` off so the RDAP error body remains visible:

```sh
curl -q --silent --show-error --connect-timeout 4 --max-time 12 \
  --max-filesize 131072 -H 'Accept: application/rdap+json' \
  --write-out '\nHTTP %{http_code} %{content_type}\n' \
  https://pubapi.registry.google/rdap/domain/hdaemon.dev
```

A complete registry 404 means **no registration record found**, not an offer to sell. A 200 must identify the requested domain. A timeout, rate limit, HTML error or malformed response is unknown. Price (including premium and renewal price), eligibility, registry restrictions, trademarks and company-name conflicts are separate checks. Before launch, repeat RDAP, check registrar terms and prices, and have the owner clear the name in the intended markets (e.g. [EUIPO](https://www.euipo.europa.eu/en/search-ip) and [USPTO](https://www.uspto.gov/trademarks/search)). None of those approvals, a reservation, or a purchase took place here. A preview needs no new domain.

## Words people use

I sampled first-party product and task pages on 21 November 2026 and searched public GitHub issue titles for session and fork terminology (`repo:anthropics/claude-code is:issue in:title fork conversation`; `repo:anomalyco/opencode is:issue in:title attach session`). Product pages tell us what readers are used to seeing. Issues show how people describe the job when the product does not do what they expect. Neither is a search-volume estimate or a ranking study.

| Public page or request | Wording on the page | Implication for H |
| --- | --- | --- |
| [IBM's “What is Agentic AI?”](https://www.ibm.com/think/topics/agentic-ai) | A definition page for *agentic AI*. | Someone learning what agents are has a different question from someone choosing a harness. Don't turn the landing page into a general AI glossary. |
| [Aider home](https://aider.chat/) | “AI pair programming in your terminal” | Lead with the developer and the checkout. “Terminal” tells a newcomer more than “TUI”; save TUI for the reference. The terminal alone does not distinguish H. |
| [Pi home](https://pi.dev/) | “minimal agent harness”; “Branch and share a session tree” | *Harness* makes sense to a builder; *branch* makes sense to a user. Branching itself is not unique. Show what both H clients see after a fork. Don't imply a share-by-URL feature. |
| [Claude Code common workflows](https://code.claude.com/docs/en/common-workflows) | “Resume previous conversations” and “Run parallel sessions with worktrees” are separate tasks. | Explain reconnecting, branching history and isolating files separately. Branching a conversation does not create a Git worktree. |
| [OpenCode API](https://opencode.ai/docs/api) | “List sessions”, “Fork session”, “Get server info” | Protocol readers look for operations, not a tour of the supervision tree. Give them H's endpoint names, auth boundary and event format. Don't copy another tool's routes. |
| [Claude Code issue 96694](https://github.com/anthropics/claude-code/issues/96694) and [94477](https://github.com/anthropics/claude-code/issues/94477) | “rewinding the conversation in place (without forking)” versus “conversation branching” in web/mobile clients | A visitor asking for *rewind* might mean *erase*. Show the original path still present in H. These requests are language evidence, not a claim about either tool's current feature gaps. |
| [Elixir guide](https://elixir.hexdocs.pm/supervisor-and-application.html) | “Registries and supervision trees” | BEAM developers have names for process lifetimes already. Lead their architecture page with the distinction between restarting a process and recovering a session. Don't require that vocabulary of a terminal user. |
| [OpenCode issue 53394](https://github.com/anomalyco/opencode/issues/53394) | “an attached TUI” and “the session's directory” | Attach instructions should say which workspace `hi` starts from and how to select an existing session by ID. |

## Query to page map

The queries below are editorial hypotheses based on that vocabulary, not recorded queries. Destinations are preview routes, not claims that pages are indexed. Give each task one answer; demos and references can link to it.

| Reader and intent | Query in the reader's words | Destination and proof | Next action |
| --- | --- | --- | --- |
| AI user learning the category (broad informational) | `what is agentic AI` | No dedicated target. If this reader reaches `/`, identify H as a tool for coding sessions, not a model or a general autonomous assistant. | Offer the demo as a concrete example; don't compete with general definitions. |
| Developer evaluating runtimes (category comparison) | `AI harness for local coding agents` | `/`: define the harness by its job: it keeps the conversation, dispatches model requests and runs tools against a checkout. | Compare the fork example with the reader's current workflow. |
| Developer comparing terminal agents | `local coding agent with web UI and terminal` | `/`: name the local daemon and show one conversation with two paths. | Open `/demo/` rather than commit to an install. |
| Developer trying an alternative answer | `branch a coding agent conversation at a message` | `/demo/hi/`: follow a fork at a selected entry; label both continuations. | Read `/docs/sessions/` for history vs work ownership. |
| Developer changing clients mid-task | `open my terminal agent session in the browser` | `/demo/hiweb/`: find the same session from the workspace inbox. | Follow `/docs/web/`; don't suggest a public share link. |
| Operator making a first local run | `install H coding agent daemon` | `/docs/setup/`: prerequisites, one server per store, owner login and how to tell it is running. | Connect a provider, then run `hi` in a trusted project. |
| Returning terminal user | `reattach hi to existing session` | `/docs/terminal/`: workspace picker `hi -r` versus explicit `hi -s SESSION_ID`. | Select the old session; don't create a second one to continue. |
| Cautious operator | `does local coding agent run shell commands in a sandbox` | `/docs/security/`: tools have the host user's access. Local session storage doesn't mean offline model calls. | Review provider and workspace before sending a turn. |
| Elixir/Erlang OTP developer evaluating the design | `Elixir coding agent OTP supervision tree session recovery` | `/docs/architecture/`: separate the session writer, task owner and supervisor; show what H reads from storage after a restart. | Trace an interrupted tool call rather than treating supervision as persistence. |
| Client author | `coding agent session API stream events` | `/docs/protocol/`: owner auth, JSON commands, SSE and reconnect cursor. | Follow one event from the daemon into a client. |
| Extension author | `H agent harness extensions` | `/extensions/`: show what's installed separately from built-ins, and how to disable it. | Read the selected extension's startup and trust notes. |

Prioritize the home page, the terminal and browser demos, and setup. AI-tool users can take that path without knowing Elixir. Give BEAM developers a direct link to the architecture instead of putting a supervision diagram in everyone's first-run instructions. Don't target “hosted AI agent”, “offline LLM” or “Git branch manager” just because their words overlap. For a check before publication, ask a terminal user to find how to keep two answers and then reattach. If they start making a second checkout or looking for a share link, revise the labels. After launch, compare actual search queries and landing pages with this map before commissioning more pages.
