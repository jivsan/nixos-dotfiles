# muninn-ro

a read-only view of my whole vault and two graphs (my notes, my nixos repo), for my `muninn-ro` cli,
hermes, grok build and, later, grok bot over my tailnet. nothing here can write to the vault, start an
agent or call a model. the nix side is `hosts/heimdall/modules/system/muninn-ro.nix`.

## how it works

- `build-view.py` runs a minute after boot or deploy and then every 15 minutes, as the `muninn-ro`
  user. it copies every note into `/var/lib/muninn-ro/view` and skips `.obsidian`, `.trash`,
  `_templates`, `.git` and anything that isn't markdown. if it can't list a folder (an nfs hiccup) the
  build fails and the last good view stays.
- a note is left out whole if it has:
  - a secret-shaped line (keys, tokens, passwords, private keys, jwts, bearer headers, urls with a
    password, totp seeds, long random strings). no `:` or `=` needed: "password is …", "totp JBSW…",
    or a long random or hex string just after a word like token, key, secret, api or auth,
  - a word from my deny file,
  - hidden characters (zero-width, bidi controls, tag characters),
  - lines aimed at agents ("ignore previous instructions", "system prompt:", tool-call markup).
- emails become `(email)`, public ips `(public ip)`. links to a note that isn't in the view become
  `(private note)`.
- the notes graph is huginn's vault graph, cut down to the notes in the view. a node from a note that
  isn't in the view goes, and so do its edges and its community's name. if anything is left that
  isn't in the view, the build keeps the last good copy (cut to today's notes), or an empty graph.
- the dotfiles graph is a copy of huginn's.
- `muninn-ro.py` serves the view on 127.0.0.1:8095: rest (GET only) and `/mcp` (POST only, stateless).
  it has no network of its own and sees nothing but the view.

## my files on heimdall (root 0600, not in git)

- `/var/lib/secrets/muninn-ro-exclude.txt`: globs, one a line. `journal/*` or `journal/` leave out a
  folder, `Areas/x.md` one note, `*health*` any path with that in it.
- `/var/lib/secrets/muninn-ro-deny.txt`: words or names, one a line. any note with one is left out.
- `/var/lib/secrets/muninn-ro-clients`: made by `sudo muninn-ro-token add|revoke <name>`.

the next build picks up exclude and deny changes: `sudo systemctl start muninn-ro-build` for now.

- what it left out and why: `sudo cat /var/lib/muninn-ro/drops.log` (path and reason, never the text)
- the counts of the last build: `journalctl -u muninn-ro-build -n 5`
- who asked what: `journalctl -u muninn-ro` (client, method, path, status. never the search words)

## clients

one token per client, so i can revoke one alone:

```
(umask 077; mkdir -p ~/.config/muninn-ro; ssh christina@10.0.20.17 'sudo muninn-ro-token add mjolnir' > ~/.config/muninn-ro/token)
muninn-ro search pi-hole
muninn-ro read "Areas/Homelab.md"
muninn-ro graph --dotfiles traefik
```

an mcp client uses `https://muninn-ro.oryxserver.org/mcp` with `Authorization: Bearer <token>`.
it must not send an `Origin` header (browsers do, so they get 403).

on my tailnet it's `services.muninn-ro.tailscaleServe` (off). while it's off, every boot and switch
runs `tailscale serve --https=8443 off`, so 8443 is muninn-ro's: i don't serve anything else there.

## tests

```
nix shell --impure --expr 'with (builtins.getFlake (toString ./.)).nixosConfigurations.heimdall.pkgs; python3.withPackages (ps: [ ps.mcp ps.uvicorn ps.httpx ])' \
  -c sh -c 'cd hosts/heimdall/muninn/ro && python3 -m unittest test_build_view test_server'
```

every note in the tests is made up.
