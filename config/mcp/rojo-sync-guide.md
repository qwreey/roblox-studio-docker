Putting a Rojo project into this Studio

Run `studio-sync` from a shell in code-docker (where the project's files are), in the project's directory. It starts the project's own `rojo serve` (the version mise or PATH picks), syncs the open place once, and stops it - no click in Studio, nothing written to the repository. Don't recreate the project's files through MCP tools instead.

    studio-sync                                   # default.project.json; owner = your git branch
    studio-sync path/to/x.project.json --owner my-task --json
    studio-sync --release                         # clear your AgentOwner marks, instances stay
    studio-sync --help

- Ownership: every top-level instance it syncs (directly under a service) gets an `AgentOwner` attribute with your owner name. A sync that would change instances another owner holds is refused (exit 1); concurrent syncs run one after another. Release your marks with `--release` when you're done so others may change them.
- Needs: Studio running with a place open (`list_roblox_studios` shows it). The sync plugin is installed when the studio container boots and Studio loads plugins only at start, so a Studio started before that needs a restart - a person at Studio's screen does that.
- Check the result with MCP tools (`search_game_tree`, `inspect_instance`) or `studio-output -n 100 --no-follow` in code-docker, which prints Studio's Output window (everyone's output, not only yours).
- `rojo serve` processes you may see in code-docker are not this: `rojo sourcemap --watch` belongs to the luau-lsp editor extension, and a live `rojo serve` is a person's own session (below).
- Live sync, for a person: `rojo serve --address 0.0.0.0` on a port in 34872-34879, then Studio's Rojo plugin connects to host `roblox-studio-front` on that port. That takes clicks in Studio, so an agent uses `studio-sync`.
