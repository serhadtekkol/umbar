# Security policy

## Report a vulnerability

Report vulnerabilities in umbar privately, through this repository's **Security** tab:
**Security > Report a vulnerability**. Do not open a public issue for a security problem.

Include:

- the umbar version and build number, from **Settings > About**;
- the macOS version;
- the steps to reproduce the problem, and what an attacker gains.

umbar is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch). If the
vulnerability is also present in upstream boring.notch, report it to that project as well, through
its own security policy.

Report vulnerabilities in a third-party component (listed in
[THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)) to the people who maintain that component.

## Getting a fix

umbar has no automatic updater. Security fixes ship in a new release, which you install by hand
as described in [README.md](README.md#update).
