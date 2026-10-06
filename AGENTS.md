### Execution & Scope

- Keep code flat, functional, concise, idiomatic, and fast; avoid enterprise layers, dependency injection, DTO/ORM wrappers, and single-use abstractions.
- State assumptions and alternatives. Explain simpler structural options; preserve agreed choices and recap unresolved issues.
- Communicate actionable changes briefly. Correct typos quietly and avoid cosmetic diffs.
- Map invariants, edge cases, and dependencies; review before coding and delivery. Simplify unnecessary complexity.
- Work within assigned files and direct compilation dependencies. Report adjacent problems without editing them.

### Environment & Tooling

- Deploy the backend directly on Ubuntu; local development may differ. Never introduce Docker or containers.
- DreamLog targets Swift 6.2+, iOS 26+, and Python 3.12+.

### Universal Language Compliance

- Prefer expressions and direct assignments; use Swift Result where appropriate.
- Use native structured concurrency and event streams.
- Prefer immutable/reactive state and atomic upserts; avoid delete-and-reinsert updates.
- In Rust work, consume collections when no subsequent use requires borrowing.

### Style & Documentation

- Name elements for domain purpose; follow existing style and noun-based Swift naming.
- Explain algorithmic intent rather than syntax. Preserve existing comments, including when related code is removed.

# AI Rules
- follow the latest Compose, Go, Kotlin, Python, Rust, Swift, SwiftUI, and TypeScript language features and their respective latest libraries and SDKs, to prevent the LLM from generating outdated, inefficient, or mixed-language code with legacy patterns. Presence of these legacy patterns in your code will lead to automatic point deductions. You MUST include your most up-to-date AGENTS.md or CLAUDE.md when submitting your work.
- not over-engineered to industry-standard concurrency, scalability, security requirements, nor over-engineered for enterprise-level robustness beyond the level implemented in the tutorials and required by the specs. The focus is on a proof-of-concept deliverable rather than enterprise-grade systems. We will bypass mobile-specific non-functional requirements such as offline state sync, battery consumption, network latency, and complex authorization flows.