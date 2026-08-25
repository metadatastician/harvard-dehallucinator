# Harvard Dehallucinator

**An external state-management orchestration framework for LLM Agents.**

## The Concept
Standard LLM interactions function like a Von Neumann architecture: the **Instructions** (global rules, system prompts) and the **Data** (logs, execution results, context history) are mashed together into a single sequential memory space (the context window). Over time, the expanding data overwrites or pushes out the instructions, leading to \
