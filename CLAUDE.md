### Execution & Scope
* **Craftsman's Creed**: Write flat, functional, concise, idiomatic, ultra-performant code, in absolute terms, without enterprise abstractions, dependency injection, or wrappers (DTO, ORM). Static peer-review before output.
* **System 2 Planning:** Map invariants, edge cases, and dependencies. State assumptions explicitly. Look beyond the direct question at the broader intent. If a simpler, cleaner, more holistic, and more performant alternatives exists, present it and briefly explain the structural "why." Peer-review statically before coding. Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify. 
* **High-Density Output:** Deliver concise, actionable edits. Eliminate all conversational filler or pleasantries. Silently fix syntax and typos. Omit cosmetic diff clutter. Once a design or code pattern choice is made, prefer it for the rest of the work session. After every choice confirmation, recap any unresolved issues from prior turns. 
* **Strict Scoping:** Limit analysis to assigned task files. Step outside strictly to resolve direct, uncompiled dependencies, then return immediately. No abstractions for single-use code. Every changed line should trace directly to the user's request. Surface dead code and adjacent code that contradicts requested change - don't auto-edit.

### Environment & Tooling
* **Target:** Back end bare-metal Ubuntu deployment, local dev may be on a different platform not set up for deployment. NEVER suggest Docker or other containers.
* **Cutting-Edge Platforms:** Target latest toolchains (Swift 6.2+, Kotlin 2.4+, iOS 26+, Android API Level 34+, Go 1.26+, Python 3.12+, Rust 1.97+, TypeScript 7+).

### Universal Language Compliance
* **Expressions Over Statements:** Prefer direct assignment (`switch`, `when`, ternaries, comprehensions, Kotlin scope functions) over multi-line `if-else`. Prefer Kotlin and Swift Result type to handle exception over `try-catch`.
* **Modern Async & Streams:** Enforce native structured concurrency and event streams over legacy thread queues or publisher wrappers.
* **State & DB Mechanics:** Prefer native immutable/reactive state flows. Enforce atomic upserts (`ON CONFLICT...DO UPDATE`) over destructive `DELETE + INSERT`.
* **Rust Ownership Rule**: Always consume collections directly when it is not used later in the scope. Do not borrow or use lifetime adapters on unneeded temporary collections when you can consume.

### Style & Documentation
* **Semantic Variables:** Name elements by functional, system-level purpose—-never implementation details. Per Swift naming scheme, names should read as nouns, not meaningless tags. Match existing style, even if you'd do it differently.
* **Strategic Comments:** Document exclusively *why* an algorithm exists. Never comment on *what* syntax does. Don't remove existing comments, leave them dangling if matching code removed.


### AI Rules
- follow the latest Compose, Go, Kotlin, Python, Rust, Swift, SwiftUI, and TypeScript language features and their respective latest libraries and SDKs, to prevent the LLM from generating outdated, inefficient, or mixed-language code with legacy patterns. Presence of these legacy patterns in your code will lead to automatic point deductions. You MUST include your most up-to-date AGENTS.md or CLAUDE.md when submitting your work.
- not over-engineered to industry-standard concurrency, scalability, security requirements, nor over-engineered for enterprise-level robustness beyond the level implemented in the tutorials and required by the specs. The focus is on a proof-of-concept deliverable rather than enterprise-grade systems. We will bypass mobile-specific non-functional requirements such as offline state sync, battery consumption, network latency, and complex authorization flows.